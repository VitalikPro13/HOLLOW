import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/audio_playback_provider.dart';
import 'package:hollow/src/core/providers/video_playback_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/video_message_bubble.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// File extensions we will hand to a player. A social adapter is supposed to
/// give us a direct media file; anything else (a watch page, a playlist, an
/// embed URL) opens in the browser instead of being fed to the decoder.
const _kPlayableVideoExtensions = {'.mp4', '.webm', '.m4v', '.mov'};

/// Whether [url] points at a direct video file we can actually play inline.
///
/// This is what separates X from YouTube, and the difference is the source,
/// not the player: FxEmbed hands back a real `.mp4` on video.twimg.com, while
/// YouTube has no direct URL at all — its player pulls signed, short-lived
/// DASH segments, so inline playback would need a WebView or a
/// signature-extraction library. TikTok's key-free oEmbed returns no media
/// URL either.
///
/// Those hosts still set `video_url`, to the media PAGE rather than a file,
/// so the card keeps its "there's a video here" affordance — this predicate
/// is what turns that into "open the page" instead of "hand it to a decoder".
bool isDirectPlayableVideo(String? url) {
  if (url == null || url.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return false;
  }
  final path = uri.path.toLowerCase();
  return _kPlayableVideoExtensions.any(path.endsWith);
}

/// Rendered link preview card inside a chat bubble.
///
/// Two layouts, chosen by the SENDER via `preview.kind` (issue #45):
///
///  * **compact** (`kind == null`) — the original row: 80px thumb on the left,
///    title, description clipped to 3 lines. What a plain OpenGraph page gets.
///  * **large** (`kind == "large"`) — image across the top, fitted (never
///    cropped, never stretched) into the card width by
///    [_LinkPreviewCardState._maxMediaHeight], then site, author, and up to 6
///    lines of body. What the social adapters emit, because a post's text IS
///    the content and a 3-line clip throws most of it away.
///
/// **Rendering never touches the network.** Every byte of the card travelled
/// with the message; receivers do not fetch the previewed URL to draw it.
/// That is a privacy property, not a cache optimization.
///
/// Tapping PLAY on a post with a direct video is the one request this widget
/// can make, and it is a deliberate exception: an explicit gesture, the same
/// trust as clicking through to the link, and `video_url` is inside the v2
/// signature so the button can only ever reach what the author's own client
/// found. The domain stays visible next to it either way. Nothing autoplays.
///
/// Phase 6.75, extended for issue #45.
class LinkPreviewCard extends ConsumerStatefulWidget {
  final network_api.LinkPreviewRef preview;

  /// Owning message id. Used only to key the single-playback slot, so the
  /// same link posted twice doesn't leave two cards fighting over it.
  final String? messageId;

  const LinkPreviewCard({super.key, required this.preview, this.messageId});

  @override
  ConsumerState<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

enum _CardVideoState { poster, preparing, playing }

class _LinkPreviewCardState extends ConsumerState<LinkPreviewCard> {
  static const double _maxWidth = 400;

  /// Tallest the media area may be, whatever shape the source is.
  ///
  /// Aspect alone does not bound a card: a 16:9 thumbnail across 400px is
  /// 225px tall, but the SAME rule on a 9:16 reel poster is 700px, and the
  /// bubble became a monolith you had to scroll past (Instagram, TikTok —
  /// anything vertical). Landscape media still spans the card; portrait now
  /// gives up width instead of taking height. Same fit rule the video bubble
  /// uses in `_resolveDisplaySize`.
  static const double _maxMediaHeight = 360;

  VideoPlayerController? _controller;
  _CardVideoState _videoState = _CardVideoState.poster;
  bool _isVisible = true;

  network_api.LinkPreviewRef get preview => widget.preview;
  bool get _isLarge => preview.kind == 'large';
  bool get _canPlayInline =>
      _isLarge && isDirectPlayableVideo(preview.videoUrl);

  /// Slot key for the one-video-at-a-time provider.
  String get _playKey => 'lp:${widget.messageId ?? preview.url}';

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  /// Pause before disposing, and drop our reference first so a listener
  /// firing mid-teardown can't touch a disposed controller. Mirrors
  /// `_VideoMessageBubbleState._disposeController`.
  void _disposeController() {
    final c = _controller;
    _controller = null;
    if (c != null) {
      c.pause();
      c.dispose();
    }
  }

  void _stopPlayback() {
    _disposeController();
    if (mounted) setState(() => _videoState = _CardVideoState.poster);
  }

  Future<void> _startPlayback() async {
    final url = preview.videoUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // Claim the playback slot first: every other video/audio surface is
    // listening and will stand down before we start decoding.
    ref.read(currentlyPlayingVideoProvider.notifier).state = _playKey;
    setState(() => _videoState = _CardVideoState.preparing);

    try {
      final controller = VideoPlayerController.networkUrl(uri);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _disposeController();
      _controller = controller;
      await controller.play();
      if (!mounted) return;
      setState(() => _videoState = _CardVideoState.playing);
    } catch (_) {
      // Unreachable host, codec the backend won't take, dead CDN link: fall
      // back to the browser rather than leaving a dead spinner on screen.
      if (!mounted) return;
      setState(() => _videoState = _CardVideoState.poster);
      _handleTap();
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final wasVisible = _isVisible;
    _isVisible = info.visibleFraction >= 0.5;
    if (wasVisible && !_isVisible && _videoState == _CardVideoState.playing) {
      _controller?.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = Theme.of(context).extension<HollowTheme>()!;

    // Stand down when another video, or any audio, takes the slot.
    ref.listen<String?>(currentlyPlayingVideoProvider, (prev, next) {
      if (next != _playKey && _videoState != _CardVideoState.poster) {
        _stopPlayback();
      }
    });
    ref.listen<String?>(currentlyPlayingAudioProvider, (prev, next) {
      if (next != null && _videoState != _CardVideoState.poster) {
        _stopPlayback();
      }
    });

    final card = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxWidth),
      child: HollowPressable(
        // While the video is up, the card must not also open the browser —
        // taps belong to the player's own play/pause.
        onTap: _videoState == _CardVideoState.poster ? _handleTap : null,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          child: Container(
            decoration: BoxDecoration(
              color: hollow.elevated,
              border: Border(
                left: BorderSide(color: hollow.accent, width: 3),
                top: BorderSide(color: hollow.border),
                right: BorderSide(color: hollow.border),
                bottom: BorderSide(color: hollow.border),
              ),
            ),
            child: _isLarge ? _buildLarge(hollow) : _buildCompact(hollow),
          ),
        ),
      ),
    );

    // Only cards that can actually play need visibility tracking.
    if (!_canPlayInline) return card;
    return VisibilityDetector(
      key: ValueKey('lp_card_$_playKey'),
      onVisibilityChanged: _onVisibilityChanged,
      child: card,
    );
  }

  // ── Compact (plain OpenGraph) ─────────────────────────────────────────

  Widget _buildCompact(HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSquareThumbnail(hollow),
          const SizedBox(width: HollowSpacing.sm),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _headerText(hollow),
                _titleText(hollow, maxLines: 2),
                if (preview.description.isNotEmpty)
                  Text(
                    preview.description,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      height: 1.3,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Large (social post) ───────────────────────────────────────────────

  Widget _buildLarge(HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildWideImage(hollow),
        Padding(
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _headerText(hollow),
              // The author IS the title on an adapter card, so showing both
              // would just print the same line twice.
              if (preview.author != null && preview.author!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    preview.author!,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                _titleText(hollow, maxLines: 2),
              if (preview.description.isNotEmpty)
                Text(
                  preview.description,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    height: 1.35,
                  ),
                  // Six, not three: a post's body is the point of the card.
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Media area: the poster at the sender's aspect ratio, FITTED into the card
  /// rather than stretched across it, and — for a post carrying a direct video
  /// — the inline player once tapped.
  ///
  /// The fit is the whole point (see [_maxMediaHeight]): whichever dimension
  /// would overflow is the one that gives, so a landscape thumbnail still
  /// spans the card and a portrait one narrows and centres. Nothing is
  /// cropped — the box matches the source aspect, so `BoxFit.cover` has
  /// nothing to cut.
  ///
  /// A post whose `video_url` is not a direct file (YouTube, TikTok) still
  /// gets a play badge, but tapping it opens the browser. See
  /// [isDirectPlayableVideo] for why that distinction is about the source
  /// rather than the player.
  Widget _buildWideImage(HollowTheme hollow) {
    final bytes = _thumbBytes();
    if (bytes == null) {
      // No image: a play row would have nothing to sit on, so the header
      // inside the body block carries the card on its own.
      return const SizedBox.shrink();
    }

    final w = preview.thumbW;
    final h = preview.thumbH;
    // Clamp extremes. Height is bounded by _maxMediaHeight now, so what this
    // still buys is a floor on WIDTH: an unclamped 1:8 sliver would render
    // 45px wide once contained, which is not a preview of anything.
    final ratio = (w != null && h != null && w > 0 && h > 0)
        ? (w / h).clamp(0.6, 2.4).toDouble()
        : 16 / 9;

    final image = Image.memory(
      bytes,
      fit: BoxFit.cover,
      width: double.infinity,
      gaplessPlayback: true,
      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
    );

    final hasVideo = preview.videoUrl != null && preview.videoUrl!.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Unbounded width would make `cardWidth` infinite and the fit
        // meaningless; fall back to the card's own cap.
        final cardWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _maxWidth;
        final inset = HollowSpacing.sm * 2;
        // Contain: whichever dimension would overflow is the one that gives.
        // A narrowed poster is inset, so it competes for slightly less width.
        final tall = ratio < cardWidth / _maxMediaHeight;
        final width = tall
            ? (_maxMediaHeight * ratio).clamp(0.0, cardWidth - inset)
            : cardWidth;

        final media = AspectRatio(
          aspectRatio: ratio,
          child: hasVideo ? _buildVideoArea(hollow, image) : image,
        );

        // Full-width media bleeds to the card edges and inherits its rounding.
        if (!tall) return media;

        // A narrowed poster would otherwise sit square-cornered and flush
        // against the card's rounded top, reading like a clipping bug rather
        // than a deliberate fit. Inset and round it instead.
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.sm, HollowSpacing.sm, HollowSpacing.sm, 0,
          ),
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              child: SizedBox(width: width, child: media),
            ),
          ),
        );
      },
    );
  }

  /// The media area's contents for a post that carries a video: poster with a
  /// play affordance, the spinner while the controller warms up, then the
  /// player itself. Sized by the caller.
  Widget _buildVideoArea(HollowTheme hollow, Widget image) {
    return switch (_videoState) {
      _CardVideoState.poster => _buildPoster(hollow, image),
      _CardVideoState.preparing => Stack(
          fit: StackFit.expand,
          children: [
            image,
            const ColoredBox(color: Color(0x66000000)),
            const Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      _CardVideoState.playing => InlineVideoPlayer(
          controller: _controller!,
          hollow: hollow,
          // No fullscreen: that viewer takes a disk path, and this is a
          // remote URL we deliberately never download.
        ),
    };
  }

  /// Poster with the play button. Inline-capable posts start the player;
  /// everything else hands off to the browser.
  ///
  /// The WHOLE poster is the hit target, not just the glyph. A 42px circle
  /// floating in a 400px-wide image is a dart-throw, and missing it fell
  /// through to the card's own tap and threw you out to the browser — the
  /// most annoying possible failure for "I wanted to watch this here". The
  /// glyph is now pure decoration; the tap surface is the image. Same shape
  /// as `InlineVideoPlayer`, which makes its whole frame the play/pause
  /// target rather than a small button.
  Widget _buildPoster(HollowTheme hollow, Widget image) {
    final inline = _canPlayInline;
    return Semantics(
      button: true,
      label: inline
          ? 'Play video from ${preview.domain}'
          : 'Open video on ${preview.domain}',
      child: GestureDetector(
        // Opaque: the poster swallows the tap so it never reaches the card's
        // open-in-browser handler underneath.
        behavior: HitTestBehavior.opaque,
        onTap: inline ? _startPlayback : _handleTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            Center(
              child: ExcludeSemantics(
                child: Container(
                  decoration: BoxDecoration(
                    // Scrim so the glyph stays readable over a bright poster.
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(HollowSpacing.sm),
                  child: Icon(
                    inline ? LucideIcons.play : LucideIcons.externalLink,
                    size: 26,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Shared pieces ─────────────────────────────────────────────────────

  Widget _headerText(HollowTheme hollow) {
    final header = _headerLine();
    if (header.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        header,
        style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _titleText(HollowTheme hollow, {required int maxLines}) {
    if (preview.title.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        preview.title,
        style: HollowTypography.body.copyWith(
          color: hollow.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// Decoded-thumbnail cache keyed by the base64 payload. Decoding per build
  /// minted a NEW byte buffer each time, so `MemoryImage` never matched
  /// Flutter's image cache and the WebP was re-decoded on every rebuild.
  /// A stable byte identity makes the ImageCache hit.
  static final Map<String, Uint8List> _thumbBytesCache = {};

  Uint8List? _thumbBytes() {
    final b64 = preview.thumbWebpB64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return _thumbBytesCache.putIfAbsent(b64, () {
        if (_thumbBytesCache.length > 128) _thumbBytesCache.clear();
        return base64Decode(b64);
      });
    } catch (_) {
      return null;
    }
  }

  Widget _buildSquareThumbnail(HollowTheme hollow) {
    final bytes = _thumbBytes();
    if (bytes == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: Image.memory(
        bytes,
        width: 80,
        height: 80,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) => const SizedBox.shrink(),
      ),
    );
  }

  /// Header line: "Site Name · domain", or just "domain" if no site name.
  /// The domain always shows, on both layouts — a card whose text and image
  /// came from a post still has to say plainly where tapping it goes.
  String _headerLine() {
    if (preview.siteName.isNotEmpty && preview.siteName != preview.domain) {
      return preview.domain.isNotEmpty
          ? '${preview.siteName} · ${preview.domain}'
          : preview.siteName;
    }
    return preview.domain;
  }

  Future<void> _handleTap() async {
    final uri = Uri.tryParse(preview.url);
    if (uri == null) return;
    try {
      // mode: externalApplication opens in the default browser on desktop.
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Silently swallow — user can still copy-paste the URL manually.
    }
  }
}

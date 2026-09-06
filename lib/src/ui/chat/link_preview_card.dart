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

/// Extensions we will hand to a player. Anything else (a watch page, a
/// playlist, an embed URL) opens in the browser rather than the decoder.
const _kPlayableVideoExtensions = {'.mp4', '.webm', '.m4v', '.mov'};

/// Whether [url] points at a direct video file we can play inline.
///
/// The difference is the source, not the player: some adapters hand back a real
/// `.mp4`, while YouTube and TikTok expose no direct URL at all. Those hosts
/// still set `video_url` to the media PAGE, so the card keeps its "there is a
/// video here" affordance and this predicate turns it into "open the page".
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
/// Two layouts chosen by the SENDER through `preview.kind` (issue #45): the
/// compact row for a plain OpenGraph page, and the large card the social
/// adapters emit, where the post's text IS the content.
///
/// RENDERING NEVER TOUCHES THE NETWORK. Every byte of the card travelled with
/// the message, and a receiver never fetches the previewed URL to draw it.
/// That is a privacy property, not a cache optimization.
///
/// Tapping PLAY is the one request this widget can make: an explicit gesture
/// carrying the same trust as clicking the link, and `video_url` sits inside
/// the v2 signature, so the button can only reach what the author's own client
/// found. Nothing autoplays, and the domain stays visible either way.
class LinkPreviewCard extends ConsumerStatefulWidget {
  final network_api.LinkPreviewRef preview;

  /// Owning message id, used only to key the single-playback slot so the same
  /// link posted twice does not leave two cards fighting over it.
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
  /// Aspect alone does not bound a card: the rule that makes a 16:9 thumbnail
  /// 225px tall makes a 9:16 reel poster 700px, a monolith to scroll past. So
  /// portrait media gives up width instead of taking height.
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

  /// Pauses before disposing and drops our reference first, so a listener
  /// firing mid-teardown cannot touch a disposed controller.
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

    // Claim the playback slot first, so every other surface stands down before
    // we start decoding.
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
      // Unreachable host, unsupported codec, dead CDN link: fall back to the
      // browser rather than leave a dead spinner on screen.
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
        // While the video is up, taps belong to the player's play/pause, not to
        // the card's open-in-browser.
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

    if (!_canPlayInline) return card;
    return VisibilityDetector(
      key: ValueKey('lp_card_$_playKey'),
      onVisibilityChanged: _onVisibilityChanged,
      child: card,
    );
  }

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
              // The author IS the title on an adapter card, so both would print
              // the same line twice.
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
                  // A post's body is the point of the card.
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
  /// rather than stretched across it, plus the inline player once tapped.
  ///
  /// Whichever dimension would overflow is the one that gives (see
  /// [_maxMediaHeight]), and the box matches the source aspect, so nothing is
  /// cropped. A post whose `video_url` is not a direct file still gets a play
  /// badge, but tapping it opens the browser ([isDirectPlayableVideo]).
  Widget _buildWideImage(HollowTheme hollow) {
    final bytes = _thumbBytes();
    if (bytes == null) {
      // With no image a play row has nothing to sit on, so the body block's
      // header carries the card alone.
      return const SizedBox.shrink();
    }

    final w = preview.thumbW;
    final h = preview.thumbH;
    // A floor on WIDTH: an unclamped 1:8 sliver renders 45px wide once
    // contained, which is not a preview of anything.
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
        // Unbounded width makes `cardWidth` infinite and the fit meaningless.
        final cardWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : _maxWidth;
        final inset = HollowSpacing.sm * 2;
        // A narrowed poster is inset, so it competes for slightly less width.
        final tall = ratio < cardWidth / _maxMediaHeight;
        final width = tall
            ? (_maxMediaHeight * ratio).clamp(0.0, cardWidth - inset)
            : cardWidth;

        final media = AspectRatio(
          aspectRatio: ratio,
          child: hasVideo ? _buildVideoArea(hollow, image) : image,
        );

        if (!tall) return media;

        // Square-cornered and flush against the card's rounded top, a narrowed
        // poster reads as a clipping bug rather than a deliberate fit.
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

  /// The media area for a post carrying a video: poster, spinner while the
  /// controller warms up, then the player. Sized by the caller.
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
          // No fullscreen: that viewer takes a disk path, and this remote URL
          // is deliberately never downloaded.
        ),
    };
  }

  /// Poster with the play button. Inline-capable posts start the player and
  /// everything else hands off to the browser.
  ///
  /// The WHOLE poster is the hit target and the glyph is decoration: missing a
  /// 42px circle falls through to the card's own tap and throws the reader out
  /// to the browser. `InlineVideoPlayer` uses the same shape.
  Widget _buildPoster(HollowTheme hollow, Widget image) {
    final inline = _canPlayInline;
    return Semantics(
      button: true,
      label: inline
          ? 'Play video from ${preview.domain}'
          : 'Open video on ${preview.domain}',
      child: GestureDetector(
        // Opaque, so the tap never reaches the card's open-in-browser handler.
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
                    // Scrim, or the glyph vanishes on a bright poster.
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

  /// Decoded-thumbnail cache keyed by the base64 payload. A fresh buffer per
  /// build never matches `MemoryImage` in Flutter's image cache, so the WebP is
  /// re-decoded every rebuild; a stable byte identity makes the cache hit.
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

  /// Header line: "Site Name · domain", or just the domain. The domain always
  /// shows, on both layouts, so the card says where tapping it goes.
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
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Swallowed: the URL is still there to copy by hand.
    }
  }
}

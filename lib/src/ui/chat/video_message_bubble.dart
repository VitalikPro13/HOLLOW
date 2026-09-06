import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/audio_playback_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/video_playback_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/file_card_status.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// Renders a video attachment inline in a message bubble.
///
/// Two sources, told apart by `attachment.videoThumb`: a VAULT video whose
/// `diskPath` is the `.webp` poster and whose bytes are reconstructed on first
/// play, or a DIRECT P2P video whose `diskPath` is the video itself, with a
/// thumbnail extracted next to it so the bubble has something to show.
///
/// One video plays at a time, enforced through [currentlyPlayingVideoProvider].
class VideoMessageBubble extends ConsumerStatefulWidget {
  final FileAttachment attachment;

  /// Manual-download hook (issue #41). The bubble is the single face for every
  /// state, poster through download and progress to play, never a separate
  /// placeholder widget.
  final VoidCallback? onDownload;

  /// Why the bytes are not here yet: the caption under the poster and what the
  /// center control does. Defaults to the plain Download button.
  final FileCardStatus status;

  const VideoMessageBubble({
    super.key,
    required this.attachment,
    this.onDownload,
    this.status = const FileCardStatus(control: FileCardControl.download),
  });

  @override
  ConsumerState<VideoMessageBubble> createState() => _VideoMessageBubbleState();
}

enum _PlaybackState {
  thumbnail,
  preparing,
  playing,
}

class _VideoMessageBubbleState extends ConsumerState<VideoMessageBubble> {
  _PlaybackState _state = _PlaybackState.thumbnail;
  VideoPlayerController? _controller;
  ProviderSubscription<Map<String, FileTransferState>>? _vaultListener;
  bool _isVisible = true;

  /// Disk path of the currently-loaded video, stashed so the fullscreen handoff
  /// need not round-trip the controller's `Uri.file()` back to a path.
  String? _activeVideoPath;

  /// Local thumbnail cache path for direct P2P videos. Null until extraction
  /// completes, and for a vault thumbnail, which is already an image on disk.
  String? _localThumbPath;
  bool _thumbExtractStarted = false;

  /// Envelope-borne poster frame (FileHeader `thumb`, issue #41), so the bubble
  /// shows a real preview before any video bytes are local. The locally
  /// extracted 480p thumbnail supersedes it.
  Uint8List? _posterBytes;

  /// Intrinsic poster dimensions: the display-aspect fallback when the header
  /// carried no width or height (old sender, or a failed ffmpeg probe).
  Size? _posterDims;

  network_api.VideoThumbRef? get _vthumb => widget.attachment.videoThumb;

  /// This bubble's key in the "currently playing" provider.
  String get _playKey => widget.attachment.fileId;

  @override
  void initState() {
    super.initState();
    // Vault videos already have a thumbnail image at attachment.diskPath.
    _maybeExtractLocalThumb();
    _decodePoster();
  }

  @override
  void didUpdateWidget(covariant VideoMessageBubble old) {
    super.didUpdateWidget(old);
    // The diskPath may arrive only once the transfer completes, so extraction
    // is retried here.
    if (_localThumbPath == null) {
      _maybeExtractLocalThumb();
    }
    if (old.attachment.thumbB64 != widget.attachment.thumbB64) {
      _posterBytes = null;
      _posterDims = null;
      _decodePoster();
    }
  }

  /// Decodes the header poster. The bytes are a tiny base64 blob, so only the
  /// intrinsic dimensions go async, and only when the attachment has no w/h.
  void _decodePoster() {
    final b64 = widget.attachment.thumbB64;
    if (b64 == null || b64.isEmpty) return;
    Uint8List bytes;
    try {
      bytes = base64Decode(b64);
    } catch (_) {
      return;
    }
    _posterBytes = bytes;
    final hasDims = widget.attachment.width != null &&
        widget.attachment.height != null &&
        widget.attachment.height! > 0;
    if (hasDims) return;
    decodeImageFromList(bytes).then((img) {
      final dims = Size(img.width.toDouble(), img.height.toDouble());
      img.dispose();
      if (mounted && dims.height > 0) {
        setState(() => _posterDims = dims);
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _vaultListener?.close();
    _disposeController();
    super.dispose();
  }

  void _disposeController() {
    final c = _controller;
    _controller = null;
    if (c != null) {
      c.pause();
      c.dispose();
    }
  }

  Future<void> _maybeExtractLocalThumb() async {
    if (_thumbExtractStarted) return;
    if (_vthumb != null) return;
    final videoPath = _resolveVideoPath();
    if (videoPath == null) return;

    _thumbExtractStarted = true;

    final cached = VideoThumbnailService.cachedThumbFor(videoPath);
    if (cached != null) {
      if (mounted) setState(() => _localThumbPath = cached);
      return;
    }

    final extracted = await VideoThumbnailService.ensureCachedThumb(videoPath);
    if (extracted != null && mounted) {
      setState(() => _localThumbPath = extracted);
    }
  }

  /// The thumbnail image to display, or null when the bubble must fall back to
  /// its placeholder.
  String? _resolveThumbnailImagePath() {
    // For a vault video attachment.diskPath IS the thumbnail .webp.
    if (_vthumb != null) {
      final p = widget.attachment.diskPath;
      if (p != null && File(p).existsSync()) return p;
      return null;
    }
    return _localThumbPath;
  }

  String? _resolveVideoPath() {
    if (_vthumb != null) return null;
    final attachPath = widget.attachment.diskPath;
    if (attachPath != null && File(attachPath).existsSync()) return attachPath;
    final transfer = ref.read(fileTransferProvider)[widget.attachment.fileId];
    final transferPath = transfer?.diskPath;
    if (transferPath != null && File(transferPath).existsSync()) return transferPath;
    return null;
  }

  bool _canPlay() {
    if (_vthumb != null) return true;
    return _resolveVideoPath() != null;
  }

  Future<void> _onPlayTapped({bool fullscreen = false}) async {
    if (!_canPlay()) return;
    ref.read(currentlyPlayingVideoProvider.notifier).state = _playKey;

    final vthumb = _vthumb;
    String? videoPath;
    if (vthumb != null) {
      setState(() => _state = _PlaybackState.preparing);
      videoPath = await _resolveVaultVideoPath(vthumb);
      if (videoPath == null) {
        if (mounted) setState(() => _state = _PlaybackState.thumbnail);
        return;
      }
    } else {
      videoPath = _resolveVideoPath();
    }

    if (videoPath == null) return;

    if (fullscreen) {
      _disposeController();
      if (mounted) setState(() => _state = _PlaybackState.thumbnail);
      if (!mounted) return;
      _showFullscreenPlayer(context, videoPath);
      return;
    }

    await _initController(videoPath);
  }

  /// The disk path of the vault video, fetching it when the cache is cold.
  /// Waits on the file transfer event stream, and returns null on failure.
  Future<String?> _resolveVaultVideoPath(network_api.VideoThumbRef vthumb) async {
    final serverId = ref.read(selectedServerProvider);
    if (serverId == null) return null;

    String diskPath;
    try {
      diskPath = await crdt_api.vaultDownloadFile(
        serverId: serverId,
        contentId: vthumb.cid,
      );
    } catch (e) {
      debugPrint('[VideoBubble] vault_download_file failed: $e');
      return null;
    }
    if (diskPath.isNotEmpty) return diskPath;

    final completer = Completer<String?>();
    _vaultListener?.close();
    final completeKey = 'vault:${vthumb.cid}';
    _vaultListener = ref.listenManual<Map<String, FileTransferState>>(
      fileTransferProvider,
      (prev, next) {
        FileTransferState? match = next[completeKey];
        if (match == null) {
          for (final s in next.values) {
            if (s.contentId == vthumb.cid && s.isComplete) {
              match = s;
              break;
            }
          }
        }
        if (match != null && match.isComplete && match.diskPath != null) {
          if (!completer.isCompleted) {
            completer.complete(match.diskPath);
          }
        }
      },
    );
    final result = await completer.future
        .timeout(const Duration(minutes: 2), onTimeout: () => null);
    _vaultListener?.close();
    _vaultListener = null;
    return result;
  }

  /// The share root hash for a file, matched on its disk path.
  String? _findShareRootHash(String diskPath) {
    final shares = ref.read(shareTabProvider);
    for (final s in shares) {
      if (s.diskPath == diskPath) return s.rootHash;
    }
    return null;
  }

  Future<void> _initController(String videoPath) async {
    if (mounted) setState(() => _state = _PlaybackState.preparing);
    try {
      final controller = VideoPlayerController.file(File(videoPath));
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      _disposeController();
      _controller = controller;
      _activeVideoPath = videoPath;
      controller.setLooping(false);
      await controller.play();
      if (mounted) setState(() => _state = _PlaybackState.playing);
    } catch (e) {
      debugPrint('[VideoBubble] failed to initialize player: $e');
      if (mounted) setState(() => _state = _PlaybackState.thumbnail);
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final wasVisible = _isVisible;
    _isVisible = info.visibleFraction >= 0.5;
    if (wasVisible && !_isVisible && _state == _PlaybackState.playing) {
      _controller?.pause();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    ref.listen<String?>(currentlyPlayingVideoProvider, (prev, next) {
      if (next != _playKey && _state == _PlaybackState.playing) {
        _disposeController();
        if (mounted) setState(() => _state = _PlaybackState.thumbnail);
      }
    });

    // Audio and video share one playback slot.
    ref.listen<String?>(currentlyPlayingAudioProvider, (prev, next) {
      if (next != null && _state == _PlaybackState.playing) {
        _disposeController();
        if (mounted) setState(() => _state = _PlaybackState.thumbnail);
      }
    });

    final size = _resolveDisplaySize();

    return VisibilityDetector(
      key: ValueKey('video_bubble_${widget.attachment.fileId}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: RepaintBoundary(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: switch (_state) {
              _PlaybackState.thumbnail => _buildThumbnail(hollow),
              _PlaybackState.preparing => _buildPreparing(hollow),
              _PlaybackState.playing => InlineVideoPlayer(
                  controller: _controller!,
                  hollow: hollow,
                  onFullscreen: () {
                    final path = _activeVideoPath;
                    _disposeController();
                    if (mounted) {
                      setState(() => _state = _PlaybackState.thumbnail);
                    }
                    if (path != null && mounted) {
                      _showFullscreenPlayer(context, path);
                    }
                  },
                ),
            },
          ),
        ),
      ),
    );
  }

  /// The bubble's display dimensions, from the FileHeader's pixel dimensions so
  /// image and video bubbles share one source of truth.
  ///
  /// Falls back to the poster's intrinsic aspect and then to 16:9, for an old
  /// client or a failed ffmpeg probe that left no dimensions.
  Size _resolveDisplaySize() {
    const maxWidth = 320.0;
    const maxHeight = 260.0;
    double? srcW = widget.attachment.width?.toDouble();
    double? srcH = widget.attachment.height?.toDouble();
    if ((srcW == null || srcH == null || srcH <= 0) && _posterDims != null) {
      srcW = _posterDims!.width;
      srcH = _posterDims!.height;
    }
    if (srcW != null && srcH != null && srcH > 0) {
      final aspect = srcW / srcH;
      double w, h;
      if (aspect > maxWidth / maxHeight) {
        w = maxWidth;
        h = maxWidth / aspect;
      } else {
        h = maxHeight;
        w = maxHeight * aspect;
      }
      return Size(w, h);
    }
    return const Size(maxWidth, maxWidth * 9 / 16);
  }

  /// Poster layer shared by the thumbnail and preparing states, in precedence
  /// order: local extracted thumbnail, header poster, dark gradient. Never a
  /// flat black slab.
  Widget _posterLayer(String? thumbPath) {
    if (thumbPath != null) {
      return Image.file(
        File(thumbPath),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, e, s) => _posterFallbackLayer(),
      );
    }
    return _posterFallbackLayer();
  }

  Widget _posterFallbackLayer() {
    final poster = _posterBytes;
    if (poster != null) {
      return Image.memory(
        poster,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, e, s) => const _VideoBackdrop(),
      );
    }
    return const _VideoBackdrop();
  }

  Widget _buildThumbnail(HollowTheme hollow) {
    final thumbPath = _resolveThumbnailImagePath();
    final canPlay = _canPlay();

    // Per-file select: fileTransferProvider replaces its whole map on EVERY
    // chunk event, so an unrelated download rebuilds every visible thumbnail.
    final transfer = ref.watch(
        fileTransferProvider.select((t) => t[widget.attachment.fileId]));
    final isDownloading = transfer != null &&
        !transfer.isComplete &&
        !transfer.declined &&
        (transfer.isDownloading || transfer.totalChunks > 0);
    final progress = isDownloading ? transfer.progress : 0.0;
    final control = widget.status.control;
    // Why the bytes are missing, said over the poster instead of behind an
    // inert button. A share with an empty swarm is one more peer to wait for.
    final blocked = !canPlay &&
        !isDownloading &&
        widget.status.caption != null &&
        control != FileCardControl.download;
    // No local bytes and nothing in flight makes the center control a download
    // button rather than an inert play button (issue #41).
    final showDownload = !canPlay &&
        !isDownloading &&
        widget.onDownload != null &&
        (control == FileCardControl.download ||
            control == FileCardControl.retry);
    // "Keep & Seed" only applies to a cached channel download in vault_cache/.
    final resolvedDiskPath = transfer?.diskPath ?? widget.attachment.diskPath;
    final isInVaultCache = resolvedDiskPath != null &&
        resolvedDiskPath.contains('vault_cache');
    final shareRoot = transfer?.shareRootHash ??
        (isInVaultCache ? _findShareRootHash(resolvedDiskPath!) : null);
    final showKeepAndSeed = shareRoot != null && isInVaultCache;

    final tapAction = canPlay
        ? _onPlayTapped
        : (showDownload ? () => widget.onDownload!() : null);
    // A surface that takes no taps must not be announced as a button, nor offer
    // "Download" to a screen reader.
    final semanticLabel = canPlay
        ? 'Play ${widget.attachment.fileName}'
        : (showDownload ? 'Download ${widget.attachment.fileName}' : null);

    return HollowFocusRing(
      enabled: tapAction != null,
      onActivate: tapAction,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: MouseRegion(
      cursor: tapAction != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: tapAction,
        child: Semantics(
        button: tapAction != null,
        label: semanticLabel,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _posterLayer(thumbPath),
            if (blocked)
              Container(
                color: Colors.black.withValues(alpha: 0.65),
                child: Center(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (control == FileCardControl.busy)
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              valueColor:
                                  AlwaysStoppedAnimation(hollow.textSecondary),
                              backgroundColor: Colors.white24,
                            ),
                          )
                        else
                          Icon(LucideIcons.cloudOff,
                              color: hollow.textSecondary, size: 32),
                        const SizedBox(height: HollowSpacing.xs),
                        Text(widget.status.caption!,
                          textAlign: TextAlign.center,
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              )
            else if (isDownloading && !canPlay)
              // The progress ring takes the same circle the play and download
              // buttons occupy, so the swap never reads as a different widget.
              Center(
                child: _CenterCircle(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                      value: progress > 0 ? progress.clamp(0.0, 1.0) : null,
                      strokeWidth: 3,
                      valueColor: const AlwaysStoppedAnimation(Colors.white),
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ),
              )
            else
              Center(
                child: _CenterCircle(
                  child: Icon(
                    canPlay ? LucideIcons.play : LucideIcons.download,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            if (isDownloading)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  minHeight: 3,
                  color: hollow.accent,
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                ),
              ),
            if (isDownloading)
              Positioned(
                left: HollowSpacing.sm,
                bottom: HollowSpacing.sm + 3,
                child: _Badge(
                  text: '${(progress * 100).toInt()}%',
                  hollow: hollow,
                ),
              )
            else if (_vthumb != null && _vthumb!.durMs > 0)
              Positioned(
                left: HollowSpacing.sm,
                bottom: HollowSpacing.sm,
                child: _Badge(text: _formatDuration(_vthumb!.durMs), hollow: hollow),
              ),
            Positioned(
              right: HollowSpacing.sm,
              bottom: HollowSpacing.sm,
              child: _Badge(
                text: _formatBytes(
                  _vthumb != null
                      ? _vthumb!.size.toInt()
                      : widget.attachment.sizeBytes,
                ),
                hollow: hollow,
              ),
            ),
            if (showKeepAndSeed && _state == _PlaybackState.thumbnail)
              Positioned(
                right: HollowSpacing.sm,
                top: HollowSpacing.sm,
                child: _KeepAndSeedButton(
                  rootHash: shareRoot!,
                  hollow: hollow,
                ),
              ),
          ],
        ),
        ),
      ),
      ),
    );
  }

  Widget _buildPreparing(HollowTheme hollow) {
    final thumbPath = _resolveThumbnailImagePath();

    // Watch ONLY the derived phase string, so a per-chunk map replacement in
    // fileTransferProvider no-ops unless the text itself changes.
    final vthumb = _vthumb;
    final phase = ref.watch(fileTransferProvider.select((t) {
      if (vthumb == null) return 'Loading...';
      for (final s in t.values) {
        if (s.contentId == vthumb.cid) {
          return s.vaultPhase ?? 'Preparing video...';
        }
      }
      return 'Preparing video...';
    }));

    return Stack(
      fit: StackFit.expand,
      children: [
        _posterLayer(thumbPath),
        Container(color: Colors.black.withValues(alpha: 0.5)),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation(hollow.accent),
                backgroundColor: Colors.white24,
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              phase,
              style: HollowTypography.caption
                  .copyWith(color: Colors.white, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ],
    );
  }

  void _showFullscreenPlayer(BuildContext context, String videoPath) {
    showHollowDialog(
      context: context,
      builder: (_) => _FullscreenVideoView(videoPath: videoPath),
    );
  }
}

/// Inline player wrapper owning the control bar's auto-fade timer.
///
/// The [controller] belongs to the PARENT: this widget never disposes it.
/// Shared with [LinkPreviewCard] (issue #45) so both surfaces get the same
/// controls rather than a second half-built player.
class InlineVideoPlayer extends StatefulWidget {
  final VideoPlayerController controller;
  final HollowTheme hollow;

  /// Fullscreen handoff. Cards pass null, because their source is a remote URL
  /// and the fullscreen viewer takes a disk path.
  final VoidCallback? onFullscreen;

  const InlineVideoPlayer({
    super.key,
    required this.controller,
    required this.hollow,
    this.onFullscreen,
  });

  @override
  State<InlineVideoPlayer> createState() => InlineVideoPlayerState();
}

class InlineVideoPlayerState extends State<InlineVideoPlayer> {
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerTick);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onControllerTick);
    super.dispose();
  }

  void _onControllerTick() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_isHovering || !widget.controller.value.isPlaying) return;
    _hideTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControlsAndReschedule() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  void _onHoverEnter(_) {
    _isHovering = true;
    _showControlsAndReschedule();
  }

  void _onHoverExit(_) {
    _isHovering = false;
    _scheduleHide();
  }

  void _togglePlayPause() {
    final c = widget.controller;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    _showControlsAndReschedule();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final hollow = widget.hollow;

    return MouseRegion(
      onEnter: _onHoverEnter,
      onExit: _onHoverExit,
      onHover: (_) => _showControlsAndReschedule(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _togglePlayPause,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              color: Colors.black,
              child: Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: _ControlBar(
                    controller: c,
                    hollow: hollow,
                    onPlayPause: _togglePlayPause,
                    onFullscreen: widget.onFullscreen,
                    // Close is fullscreen-only: inline, scrolling away is the
                    // same thing.
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  final VideoPlayerController controller;
  final HollowTheme hollow;
  final VoidCallback onPlayPause;
  /// Null hides the button: a link-preview card has no disk path to hand the
  /// fullscreen viewer.
  final VoidCallback? onFullscreen;
  final bool isFullscreen;

  const _ControlBar({
    required this.controller,
    required this.hollow,
    required this.onPlayPause,
    this.onFullscreen,
    this.isFullscreen = false,
  });

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    final isPlaying = value.isPlaying;
    final position = value.position;
    final duration = value.duration;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.75),
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.sm,
        HollowSpacing.lg,
        HollowSpacing.sm,
        HollowSpacing.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: hollow.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: hollow.accent,
              overlayColor: hollow.accent.withValues(alpha: 0.2),
            ),
            child: Slider(
              min: 0,
              max: duration.inMilliseconds.toDouble().clamp(
                    1,
                    double.infinity,
                  ),
              value: position.inMilliseconds
                  .clamp(0, duration.inMilliseconds)
                  .toDouble(),
              onChanged: (v) {
                controller.seekTo(Duration(milliseconds: v.toInt()));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
            child: Row(
              children: [
                _IconBtn(
                  icon: isPlaying ? LucideIcons.pause : LucideIcons.play,
                  onTap: onPlayPause,
                ),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  '${_fmt(position)} / ${_fmt(duration)}',
                  style: HollowTypography.caption.copyWith(
                    color: Colors.white,
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    decoration: TextDecoration.none,
                  ),
                ),
                const Spacer(),
                if (onFullscreen != null)
                  _IconBtn(
                    icon:
                        isFullscreen ? LucideIcons.minimize2 : LucideIcons.maximize2,
                    onTap: onFullscreen!,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _IconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    String label;
    if (icon == LucideIcons.play) {
      label = 'Play video';
    } else if (icon == LucideIcons.pause) {
      label = 'Pause video';
    } else if (icon == LucideIcons.maximize2) {
      label = 'Enter fullscreen';
    } else if (icon == LucideIcons.minimize2) {
      label = 'Exit fullscreen';
    } else {
      label = 'Video control';
    }
    return HollowPressable(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(4),
      padding: const EdgeInsets.all(6),
      child: Icon(icon, color: Colors.white, size: 16),
    );
  }
}

/// Fullscreen video viewer. Owns its own controller, unlike [InlineVideoPlayer].
class _FullscreenVideoView extends StatefulWidget {
  final String videoPath;

  const _FullscreenVideoView({required this.videoPath});

  @override
  State<_FullscreenVideoView> createState() => _FullscreenVideoViewState();
}

class _FullscreenVideoViewState extends State<_FullscreenVideoView> {
  VideoPlayerController? _controller;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  Future<void> _initController() async {
    try {
      final c = VideoPlayerController.file(File(widget.videoPath));
      await c.initialize();
      if (!mounted) {
        c.dispose();
        return;
      }
      c.setLooping(false);
      c.addListener(_onTick);
      await c.play();
      setState(() => _controller = c);
      _scheduleHide();
    } catch (e) {
      debugPrint('[FullscreenVideo] init failed: $e');
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_isHovering || _controller?.value.isPlaying != true) return;
    _hideTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControlsAndReschedule() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHide();
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    _showControlsAndReschedule();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    final c = _controller;
    _controller = null;
    if (c != null) {
      c.removeListener(_onTick);
      c.pause();
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final c = _controller;

    // Material so Text widgets inherit a DefaultTextStyle and skip the debug
    // yellow underline.
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(),
        child: Center(
        child: c == null || !c.value.isInitialized
            ? const SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(),
              )
            : MouseRegion(
                onEnter: (_) {
                  _isHovering = true;
                  _showControlsAndReschedule();
                },
                onExit: (_) {
                  _isHovering = false;
                  _scheduleHide();
                },
                onHover: (_) => _showControlsAndReschedule(),
                child: GestureDetector(
                  // Clicks INSIDE the player area must not dismiss.
                  behavior: HitTestBehavior.opaque,
                  onTap: _togglePlayPause,
                  child: Padding(
                    padding: const EdgeInsets.all(HollowSpacing.xxl),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(hollow.radiusMd),
                      child: AspectRatio(
                        aspectRatio: c.value.aspectRatio,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Container(
                              color: Colors.black,
                              child: VideoPlayer(c),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: AnimatedOpacity(
                                opacity: _controlsVisible ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 200),
                                child: IgnorePointer(
                                  ignoring: !_controlsVisible,
                                  child: _ControlBar(
                                    controller: c,
                                    hollow: hollow,
                                    onPlayPause: _togglePlayPause,
                                    onFullscreen: () => Navigator.of(context).pop(),
                                    isFullscreen: true,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ),
      ),
    );
  }
}

class _KeepAndSeedButton extends ConsumerStatefulWidget {
  final String rootHash;
  final HollowTheme hollow;

  const _KeepAndSeedButton({required this.rootHash, required this.hollow});

  @override
  ConsumerState<_KeepAndSeedButton> createState() => _KeepAndSeedButtonState();
}

class _KeepAndSeedButtonState extends ConsumerState<_KeepAndSeedButton> {
  bool _loading = false;
  bool? _kept;

  bool _isSeeding() {
    final shares = ref.read(shareTabProvider);
    for (final s in shares) {
      if (s.rootHash == widget.rootHash) return s.seeding;
    }
    return false;
  }

  bool _isKept() {
    if (_kept != null) return _kept!;
    final shares = ref.read(shareTabProvider);
    for (final s in shares) {
      if (s.rootHash == widget.rootHash) {
        final dp = s.diskPath;
        if (dp != null && !dp.contains('vault_cache')) return true;
      }
    }
    return false;
  }

  Future<void> _onTap() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      if (!_isKept()) {
        await share_api.shareKeepAndSeed(rootHash: widget.rootHash);
        _kept = true;
      } else {
        final nowSeeding = _isSeeding();
        await share_api.shareSetSeeding(
            rootHash: widget.rootHash, seeding: !nowSeeding);
      }
    } catch (e) {
      debugPrint('[VideoBubble] Keep & Seed toggle failed: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final shares = ref.watch(shareTabProvider);
    final seeding = shares
        .where((s) => s.rootHash == widget.rootHash)
        .map((s) => s.seeding)
        .firstOrNull ?? false;
    final kept = _isKept();

    return GestureDetector(
      onTap: _onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: seeding
              ? widget.hollow.accent.withValues(alpha: 0.8)
              : Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(widget.hollow.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_loading)
              const SizedBox(
                width: 12, height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: Colors.white),
              )
            else
              Icon(
                seeding ? LucideIcons.check : (kept ? LucideIcons.pause : LucideIcons.hardDrive),
                color: Colors.white, size: 12,
              ),
            const SizedBox(width: 4),
            Text(
              seeding ? 'Seeding' : (kept ? 'Paused' : 'Keep & Seed'),
              style: HollowTypography.caption.copyWith(
                color: Colors.white, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

/// The single 64 px scrim circle every center control lives in, so a control
/// swap never reads as a different widget.
class _CenterCircle extends StatelessWidget {
  final Widget child;

  const _CenterCircle({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.85),
          width: 2,
        ),
      ),
      child: Center(child: child),
    );
  }
}

/// Background for a video bubble with no poster. Dark in both themes, because
/// the white-on-scrim center controls need the contrast.
class _VideoBackdrop extends StatelessWidget {
  const _VideoBackdrop();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF23252B), Color(0xFF101114)],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final HollowTheme hollow;

  const _Badge({required this.text, required this.hollow});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
      ),
      child: Text(
        text,
        style: HollowTypography.caption.copyWith(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

String _formatDuration(int ms) {
  final totalSec = (ms / 1000).round();
  final m = totalSec ~/ 60;
  final s = totalSec % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

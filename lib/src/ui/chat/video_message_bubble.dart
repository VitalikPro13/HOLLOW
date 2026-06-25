import 'dart:async';
import 'dart:io';

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
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// Renders a video attachment inline in a message bubble.
///
/// **Sources of the playable video file:**
///   - **Vault video** (`attachment.videoThumb != null`) — `attachment.diskPath`
///     is the local `.webp` thumbnail file (always full-replicated via the image
///     P2P path). The video bytes live in the vault and are reconstructed on
///     first play via `vault_download_file`.
///   - **Direct P2P video** (DM or <6 member server, `videoThumb == null`) —
///     `attachment.diskPath` is the local video file itself. Each peer also
///     extracts a local thumbnail to `{file_id}.thumb.webp` next to the video,
///     so the inline bubble has something to show before play.
///
/// **States:**
///   - `_State.thumbnail` — show thumbnail image with center play button + size
///     badge. Click anywhere → start preparing/playing. Click the fullscreen
///     button → preparing/playing in a fullscreen overlay.
///   - `_State.preparing` — vault download / player initialization in flight.
///     Renders the thumbnail with a centered spinner overlay.
///   - `_State.playing` — inline `VideoPlayer` at the same dimensions as the
///     thumbnail (preview-in-place). Auto-fading thin control bar at the bottom
///     (play/pause + scrub + current/total time + fullscreen + close X).
///
/// Single-video-at-a-time enforced via [currentlyPlayingVideoProvider]: when
/// another bubble starts playing, this one observes the change and pauses.
class VideoMessageBubble extends ConsumerStatefulWidget {
  final FileAttachment attachment;

  const VideoMessageBubble({super.key, required this.attachment});

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

  /// Disk path of the currently-loaded video (set when entering preparing/
  /// playing). Stashed so the fullscreen handoff can hand the same path to
  /// the fullscreen viewer without re-parsing the controller's URI (which
  /// uses Uri.file() on Windows and would need toFilePath() to round-trip).
  String? _activeVideoPath;

  /// Local thumbnail cache path for direct P2P videos. Lazily populated
  /// after async extraction completes; null when no extraction has run yet,
  /// or when the file is a vault thumbnail (already an image on disk).
  String? _localThumbPath;
  bool _thumbExtractStarted = false;

  network_api.VideoThumbRef? get _vthumb => widget.attachment.videoThumb;

  /// Unique key for this bubble in the "currently playing" provider —
  /// the file_id of the thumbnail message (unique per chat message).
  String get _playKey => widget.attachment.fileId;

  @override
  void initState() {
    super.initState();
    // Kick off thumbnail extraction for direct P2P videos in the background.
    // Vault videos already have a thumbnail image at attachment.diskPath, so
    // we skip them.
    _maybeExtractLocalThumb();
  }

  @override
  void didUpdateWidget(covariant VideoMessageBubble old) {
    super.didUpdateWidget(old);
    // The diskPath may arrive after a P2P transfer completes (FileCompleted
    // event causes a reload). Re-attempt extraction if we don't have a
    // cached thumbnail yet.
    if (_localThumbPath == null) {
      _maybeExtractLocalThumb();
    }
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

    // Sync cache hit?
    final cached = VideoThumbnailService.cachedThumbFor(videoPath);
    if (cached != null) {
      if (mounted) setState(() => _localThumbPath = cached);
      return;
    }

    // Async extraction (file is small, ffmpeg is fast — usually <500ms).
    final extracted = await VideoThumbnailService.ensureCachedThumb(videoPath);
    if (extracted != null && mounted) {
      setState(() => _localThumbPath = extracted);
    }
  }

  // ─── Playback control ────────────────────────────────────────────

  /// Returns the path to a thumbnail image to display, or null if none is
  /// available (in which case the bubble shows a black placeholder).
  String? _resolveThumbnailImagePath() {
    // Vault video: attachment.diskPath IS the thumbnail .webp.
    if (_vthumb != null) {
      final p = widget.attachment.diskPath;
      if (p != null && File(p).existsSync()) return p;
      return null;
    }
    // Direct P2P video: locally-extracted .thumb.webp sibling.
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

  /// Returns the disk path of the vault video, fetching from the vault if
  /// the cache is cold. Blocks (via the file transfer event stream) until
  /// the reconstruction completes; returns null on failure.
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

    // Async reconstruction in flight — wait for VaultDownloadComplete.
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

  /// Find the share root hash for a file by matching its disk path against
  /// the share tab entries.
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

  // ─── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Pause when another bubble takes the playback slot.
    ref.listen<String?>(currentlyPlayingVideoProvider, (prev, next) {
      if (next != _playKey && _state == _PlaybackState.playing) {
        _disposeController();
        if (mounted) setState(() => _state = _PlaybackState.thumbnail);
      }
    });

    // Pause when an audio bubble starts playing.
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
              _PlaybackState.playing => _InlinePlayer(
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

  /// Compute the bubble's display dimensions from the source video's
  /// pixel dimensions stored in the FileHeader (`attachment.width`/`height`).
  ///
  /// For images, Rust populates these via `image::load_from_memory` during
  /// the upload pipeline. For videos (Phase 6.75), Dart pre-extracts the
  /// dimensions via `VideoThumbnailService.extractVideoThumbnail` and passes
  /// them through `network_api.sendFile(overrideWidth, overrideHeight)`,
  /// which lands in the same FileHeader fields. So both image and video
  /// bubbles can use one source of truth.
  ///
  /// Falls back to 16:9 if dimensions aren't available (shouldn't happen for
  /// videos sent by Phase 6.75 clients, but handles old clients gracefully).
  Size _resolveDisplaySize() {
    const maxWidth = 320.0;
    const maxHeight = 260.0;
    final srcW = widget.attachment.width;
    final srcH = widget.attachment.height;
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

  // ─── Thumbnail mode ───────────────────────────────────────────────

  Widget _buildThumbnail(HollowTheme hollow) {
    final thumbPath = _resolveThumbnailImagePath();
    final canPlay = _canPlay();

    final allTransfers = ref.watch(fileTransferProvider);
    final transfer = allTransfers[widget.attachment.fileId];
    final isShareBacked = transfer?.shareRootHash != null;
    final isDownloading = transfer != null &&
        !transfer.isComplete &&
        transfer.totalChunks > 0;
    final progress = isDownloading ? transfer.progress : 0.0;
    final noSeeders = isShareBacked &&
        !transfer!.isComplete &&
        (transfer.seeders ?? -1) == 0 &&
        transfer.chunksReceived == 0;
    // Show "Keep & Seed" if the file lives in vault_cache/ (cached channel download).
    final resolvedDiskPath = transfer?.diskPath ?? widget.attachment.diskPath;
    final isInVaultCache = resolvedDiskPath != null &&
        resolvedDiskPath.contains('vault_cache');
    final shareRoot = transfer?.shareRootHash ??
        (isInVaultCache ? _findShareRootHash(resolvedDiskPath!) : null);
    final showKeepAndSeed = shareRoot != null && isInVaultCache;

    return HollowFocusRing(
      enabled: canPlay,
      onActivate: canPlay ? _onPlayTapped : null,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: MouseRegion(
      cursor: canPlay ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: canPlay ? _onPlayTapped : null,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbPath != null)
              Image.file(
                File(thumbPath),
                fit: BoxFit.cover,
                errorBuilder: (_, e, s) => Container(color: Colors.black),
              )
            else
              Container(color: Colors.black),
            if (noSeeders)
              Container(
                color: Colors.black.withValues(alpha: 0.65),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.cloudOff, color: hollow.textSecondary, size: 32),
                      const SizedBox(height: HollowSpacing.xs),
                      Text('No seeders',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary, fontSize: 11)),
                    ],
                  ),
                ),
              )
            else
              // Play button — always visible (during download = tap to stream).
              Center(
                child: Container(
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
                  child: const Icon(
                    LucideIcons.play,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
              ),
            // Thin progress bar at bottom during share download.
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
            // "Keep & Seed" button for completed share-backed videos in vault_cache.
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
    );
  }

  // ─── Preparing mode ───────────────────────────────────────────────

  Widget _buildPreparing(HollowTheme hollow) {
    final thumbPath = _resolveThumbnailImagePath();

    // Watch the matching file transfer state for vault phase text.
    final vthumb = _vthumb;
    final allTransfers = ref.watch(fileTransferProvider);
    FileTransferState? transfer;
    if (vthumb != null) {
      for (final s in allTransfers.values) {
        if (s.contentId == vthumb.cid) {
          transfer = s;
          break;
        }
      }
    }
    final phase = transfer?.vaultPhase ??
        (vthumb != null ? 'Preparing video...' : 'Loading...');

    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbPath != null)
          Image.file(
            File(thumbPath),
            fit: BoxFit.cover,
            errorBuilder: (_, e, s) => Container(color: Colors.black),
          )
        else
          Container(color: Colors.black),
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

  // ─── Fullscreen launcher ──────────────────────────────────────────

  void _showFullscreenPlayer(BuildContext context, String videoPath) {
    showHollowDialog(
      context: context,
      builder: (_) => _FullscreenVideoView(videoPath: videoPath),
    );
  }
}

// ════ Inline player widget (preview-in-place) ════════════════════════════

/// Stateful inline player wrapper. Owns the auto-fade timer for the control
/// bar, and rebuilds when the controller's value changes (so the scrub bar
/// and timestamp stay in sync). The [controller] is owned by the parent
/// `_VideoMessageBubbleState`; this widget never disposes it.
class _InlinePlayer extends StatefulWidget {
  final VideoPlayerController controller;
  final HollowTheme hollow;
  final VoidCallback onFullscreen;

  const _InlinePlayer({
    required this.controller,
    required this.hollow,
    required this.onFullscreen,
  });

  @override
  State<_InlinePlayer> createState() => _InlinePlayerState();
}

class _InlinePlayerState extends State<_InlinePlayer> {
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
            // The actual video, fit-contained inside the bubble area.
            Container(
              color: Colors.black,
              child: Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            ),
            // Auto-fading control bar at the bottom.
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
                    // No close button inline — the user can just leave the
                    // video paused or scroll away. Close X is fullscreen-only.
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

// ════ Shared control bar (used by inline + fullscreen players) ═══════════

class _ControlBar extends StatelessWidget {
  final VideoPlayerController controller;
  final HollowTheme hollow;
  final VoidCallback onPlayPause;
  final VoidCallback onFullscreen;
  final bool isFullscreen;

  const _ControlBar({
    required this.controller,
    required this.hollow,
    required this.onPlayPause,
    required this.onFullscreen,
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
          // Scrub bar.
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
          // Bottom row: play/pause, time, spacer, fullscreen, close.
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
                _IconBtn(
                  icon: isFullscreen ? LucideIcons.minimize2 : LucideIcons.maximize2,
                  onTap: onFullscreen,
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

// ════ Fullscreen video viewer ═════════════════════════════════════════════

/// Fullscreen video viewer launched via showHollowDialog. Owns its own
/// VideoPlayerController initialized from the supplied videoPath. Click
/// outside the player area or the close button to dismiss.
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

    // Wrap in Material so Text widgets (timer, etc.) inherit a proper
    // DefaultTextStyle and don't render with the debug yellow underline.
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Click on the dim background to dismiss.
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
                  // Clicks INSIDE the player area should NOT dismiss.
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
                            // Auto-fading control bar.
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

// ════ Keep & Seed toggle ═════════════════════════════════════════════════

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

// ════ Helpers ═════════════════════════════════════════════════════════════

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

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/audio_playback_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/video_playback_provider.dart';
import 'package:hollow/src/core/services/audio_probe_service.dart';
import 'package:hollow/src/core/services/audio_transcode_service.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Renders an audio attachment inline in a message bubble.
///
/// Two states:
///   - **idle** — compact card with play button, file name, duration badge,
///     and file size.
///   - **playing** — same card with pause button, live scrub slider, and
///     current/total timestamps.
///
/// Single-audio-at-a-time enforced via [currentlyPlayingAudioProvider].
/// Cross-linked with [currentlyPlayingVideoProvider] — starting audio stops
/// any playing video, and vice versa.
class AudioMessageBubble extends ConsumerStatefulWidget {
  final FileAttachment attachment;

  /// Manual-download hook (issue #41 carry-over): when the audio bytes are
  /// not on disk yet, the dead play button becomes a live download button
  /// that triggers this callback (same flow as the image placeholder).
  final VoidCallback? onDownload;

  const AudioMessageBubble({super.key, required this.attachment, this.onDownload});

  @override
  ConsumerState<AudioMessageBubble> createState() =>
      _AudioMessageBubbleState();
}

enum _PlaybackState { idle, playing }

class _AudioMessageBubbleState extends ConsumerState<AudioMessageBubble> {
  _PlaybackState _state = _PlaybackState.idle;
  AudioPlayer? _player;
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _completeSub;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  bool _isVisible = true;
  bool _preparing = false;

  /// Pre-play duration from ffmpeg probe (milliseconds), or null if not yet
  /// probed / probe failed.
  int? _probedDurationMs;

  /// A probe has actually been handed to ffmpeg. Only this suppresses the
  /// deferred probe on the play tap.
  bool _probeStarted = false;

  /// The eager path has already made its decision for this file, refusal
  /// included. Keeps a refusal from being re-evaluated on every rebuild
  /// without pretending a probe happened.
  bool _eagerProbeSettled = false;

  String get _playKey => widget.attachment.fileId;

  @override
  void initState() {
    super.initState();
    _maybeProbe();
  }

  @override
  void didUpdateWidget(covariant AudioMessageBubble old) {
    super.didUpdateWidget(old);
    // Re-attempt probe if diskPath arrived after a transfer completed.
    if (!_probeStarted) _maybeProbe();
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  // ─── Duration probe ──────────────────────────────────────────────

  /// True when this attachment is a recorded voice note by every measure we
  /// have, and so may be decoded before the user asks for it.
  ///
  /// The extension routed the file here, and an extension is the sender's
  /// choice. A voice note also has to carry the recorder's name shape and a
  /// size a voice note could plausibly have.
  bool _looksLikeAVoiceNote() => isGenuineVoiceNote(
        // The wire header's `voice` flag does not reach Dart: neither
        // NetworkEvent.fileHeaderReceived nor StoredFileInfo carries it, and
        // FileAttachment has no field for it. When it is surfaced, pass it
        // here instead of this literal.
        voice: true,
        name: widget.attachment.fileName,
        ext: widget.attachment.fileExt,
        sizeBytes: widget.attachment.sizeBytes,
      );

  /// The zero-tap probe.
  ///
  /// Probing runs the bundled ffmpeg over bytes a stranger sent us, and an
  /// auto-downloaded file arrives with no interaction at all, so the eager
  /// path is kept to the one case that earns it: a genuine voice note, small,
  /// that really does open with an Ogg header on disk. A forged voice name
  /// over other bytes, an oversized ogg, and every ordinary music file wait
  /// for the play tap, which is the user asking for the decode.
  Future<void> _maybeProbe() async {
    if (_probeStarted || _eagerProbeSettled) return;
    if (!_looksLikeAVoiceNote()) return;
    final path = _resolveDiskPath();
    if (path == null) return;

    final int onDisk;
    try {
      final file = File(path);
      if (!file.existsSync()) return; // not downloaded yet, retry later
      onDisk = file.lengthSync();
    } on FileSystemException {
      return;
    }
    // The header's size is the sender's claim; this is the file we hold.
    if (onDisk > kVoiceNoteMaxBytes) return;

    // One decision per file from here on, a refusal included: the bytes will
    // not change under us, so a failed sniff must not be retried on every
    // rebuild. A refusal still leaves the play tap free to probe.
    _eagerProbeSettled = true;
    if (!await AudioProbeService.looksLikeOgg(path)) return;
    _probeStarted = true;
    await _runProbe(path);
  }

  /// Probe for the duration badge, then prewarm the transcode cache.
  Future<void> _runProbe(String path) async {
    final ms = await AudioProbeService.probeDurationMs(path);
    if (ms != null && mounted) {
      setState(() => _probedDurationMs = ms);
    }
    // Prewarm the Windows Opus→WAV transcode cache so the first play tap is
    // instant. No-op on non-Windows or non-ogg. Fire-and-forget.
    unawaited(
      AudioTranscodeService.ensurePlayable(path).catchError((_) => null),
    );
  }

  // ─── Playback control ────────────────────────────────────────────

  /// Resolve the on-disk path for this attachment. Prefers the attachment's
  /// persisted [diskPath] (set on DB hydrate) but falls back to the live
  /// transfer state so the play button flips to enabled the moment an
  /// auto-download finishes, before the chat has reloaded from DB.
  String? _resolveDiskPath() {
    final fromAttachment = widget.attachment.diskPath;
    if (fromAttachment != null) return fromAttachment;
    final transfer = ref.read(fileTransferProvider)[widget.attachment.fileId];
    return transfer?.diskPath;
  }

  bool _canPlay() {
    final path = _resolveDiskPath();
    return path != null && File(path).existsSync();
  }

  Future<void> _onPlayTapped() async {
    if (!_canPlay() || _preparing) return;
    final path = _resolveDiskPath()!;

    // Take the audio playback slot.
    ref.read(currentlyPlayingAudioProvider.notifier).state = _playKey;
    // Clear the video slot so any playing video stops.
    ref.read(currentlyPlayingVideoProvider.notifier).state = null;

    // The tap is the consent. Everything the eager gate held back happens
    // here, in front of a user who asked for it, with the button showing busy
    // while it runs.
    setState(() => _preparing = true);

    if (!_probeStarted) {
      _probeStarted = true;
      final ms = await AudioProbeService.probeDurationMs(path);
      if (!mounted) return;
      if (ms != null) setState(() => _probedDurationMs = ms);
    }

    // Windows' Media Foundation can't decode Opus-in-Ogg. For .ogg inputs we
    // transcode to a cached PCM WAV via bundled ffmpeg (no-op on other
    // platforms and for non-ogg formats). Cache hit is instant.
    String? playable;
    try {
      playable = await AudioTranscodeService.ensurePlayable(path);
    } catch (e) {
      // A file that vanished under us, a locked handle, a dead binary.
      debugPrint('[AudioBubble] prepare failed for $path: $e');
      playable = null;
    }
    if (!mounted) return;
    setState(() => _preparing = false);
    if (playable == null || !File(playable).existsSync()) {
      debugPrint('[AudioBubble] transcode failed for $path');
      if (mounted) {
        HollowToast.show(
          context,
          'Could not open this audio file',
          type: HollowToastType.error,
        );
      }
      return;
    }

    await _initPlayer(playable);
  }

  Future<void> _initPlayer(String audioPath) async {
    _disposePlayer();

    final player = AudioPlayer();
    _player = player;

    _positionSub = player.onPositionChanged.listen((pos) {
      if (mounted) setState(() => _position = pos);
    });
    _durationSub = player.onDurationChanged.listen((dur) {
      if (mounted) setState(() => _duration = dur);
    });
    _completeSub = player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _state = _PlaybackState.idle;
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });

    try {
      await player.play(DeviceFileSource(audioPath));
      if (mounted) {
        setState(() {
          _state = _PlaybackState.playing;
          _isPlaying = true;
        });
      }
    } catch (e) {
      debugPrint('[AudioBubble] play failed: $e');
      _disposePlayer();
    }
  }

  void _togglePlayPause() {
    final player = _player;
    if (player == null) return;
    if (_isPlaying) {
      player.pause();
      if (mounted) setState(() => _isPlaying = false);
    } else {
      // Re-take the playback slot on resume.
      ref.read(currentlyPlayingAudioProvider.notifier).state = _playKey;
      ref.read(currentlyPlayingVideoProvider.notifier).state = null;
      player.resume();
      if (mounted) setState(() => _isPlaying = true);
    }
  }

  void _onSeek(double value) {
    _player?.seek(Duration(milliseconds: value.toInt()));
  }

  void _disposePlayer() {
    _positionSub?.cancel();
    _positionSub = null;
    _durationSub?.cancel();
    _durationSub = null;
    _completeSub?.cancel();
    _completeSub = null;
    final p = _player;
    _player = null;
    if (p != null) {
      p.stop();
      p.dispose();
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final wasVisible = _isVisible;
    _isVisible = info.visibleFraction >= 0.5;
    if (wasVisible && !_isVisible && _isPlaying) {
      _player?.pause();
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  // ─── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Stop when another audio bubble takes the slot.
    ref.listen<String?>(currentlyPlayingAudioProvider, (prev, next) {
      if (next != _playKey && _state == _PlaybackState.playing) {
        _disposePlayer();
        if (mounted) {
          setState(() {
            _state = _PlaybackState.idle;
            _isPlaying = false;
            _position = Duration.zero;
          });
        }
      }
    });

    // Stop when a video starts playing.
    ref.listen<String?>(currentlyPlayingVideoProvider, (prev, next) {
      if (next != null && _state == _PlaybackState.playing) {
        _disposePlayer();
        if (mounted) {
          setState(() {
            _state = _PlaybackState.idle;
            _isPlaying = false;
            _position = Duration.zero;
          });
        }
      }
    });

    // Watch live transfer progress for download state.
    final transfer = ref.watch(
      fileTransferProvider.select((s) => s[widget.attachment.fileId]),
    );
    final isComplete =
        widget.attachment.isComplete || (transfer?.isComplete ?? false);
    // Kick off the duration probe the first build after the file becomes
    // available on disk (auto-download completion or late DB hydrate).
    if (isComplete && !_probeStarted) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeProbe());
    }
    final isDownloading = !isComplete && (transfer?.isDownloading ?? false);
    final vaultPhase = transfer?.vaultPhase;
    final progress = (transfer != null && transfer.progress > 0)
        ? transfer.progress
        : widget.attachment.progress;
    final totalBytes = (transfer != null && transfer.sizeBytes > 0)
        ? transfer.sizeBytes
        : widget.attachment.sizeBytes;
    final bytesReceived = (progress * totalBytes).round();

    return VisibilityDetector(
      key: ValueKey('audio_bubble_${widget.attachment.fileId}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: RepaintBoundary(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(HollowSpacing.md),
                child: _state == _PlaybackState.playing
                    ? _buildPlaying(hollow)
                    : _buildIdle(hollow, isComplete, isDownloading, vaultPhase, bytesReceived),
              ),
              // Download progress bar.
              if (isDownloading || (!isComplete && progress > 0))
                SizedBox(
                  height: 3,
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress.clamp(0.0, 1.0) : null,
                    backgroundColor: hollow.border,
                    valueColor: AlwaysStoppedAnimation(hollow.accent),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Idle state ──────────────────────────────────────────────────

  Widget _buildIdle(HollowTheme hollow, bool isComplete, bool isDownloading, String? vaultPhase, int bytesReceived) {
    final canPlay = _canPlay() && isComplete;
    // Undownloaded and idle (issue #41 carry-over): the play button would be
    // a dead dimmed control — make it a live download button instead.
    final showDownload = !canPlay &&
        !isComplete &&
        !isDownloading &&
        vaultPhase == null &&
        widget.onDownload != null;
    final durationText = _probedDurationMs != null
        ? _formatDuration(_probedDurationMs!)
        : null;

    return Row(
      children: [
        // Play button (or download button while the bytes aren't local).
        if (showDownload)
          _PlayButton(
            icon: LucideIcons.download,
            color: hollow.accent,
            onTap: widget.onDownload,
            isPlay: false,
            semanticLabel: 'Download ${widget.attachment.fileName}',
          )
        else
          _PlayButton(
            // A deferred probe or transcode can take a moment, so the button
            // says so and stops taking taps until it is done.
            icon: _preparing ? LucideIcons.loader2 : LucideIcons.play,
            color: canPlay && !_preparing
                ? hollow.accent
                : hollow.accent.withValues(alpha: 0.4),
            onTap: canPlay && !_preparing ? _onPlayTapped : null,
            semanticLabel: _preparing
                ? 'Preparing ${widget.attachment.fileName}'
                : 'Play ${widget.attachment.fileName}',
          ),
        const SizedBox(width: HollowSpacing.md),
        // File name + metadata row.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.attachment.fileName,
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: HollowSpacing.xxs),
              Row(
                children: [
                  if (durationText != null) ...[
                    Text(
                      durationText,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                    Text(
                      '  ·  ',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                  Text(
                    vaultPhase != null
                        ? '$vaultPhase  ${widget.attachment.formattedSize}'
                        : isDownloading && bytesReceived > 0
                            ? '${_formatBytes(bytesReceived)} / ${widget.attachment.formattedSize}'
                            : isDownloading
                                ? 'Downloading... ${widget.attachment.formattedSize}'
                                : widget.attachment.formattedSize,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Playing state ───────────────────────────────────────────────

  Widget _buildPlaying(HollowTheme hollow) {
    final durationMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds.toDouble()
        : (_probedDurationMs?.toDouble() ?? 1.0);
    final positionMs = _position.inMilliseconds
        .clamp(0, durationMs.toInt())
        .toDouble();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Pause/play button.
        _PlayButton(
          icon: _isPlaying ? LucideIcons.pause : LucideIcons.play,
          color: hollow.accent,
          onTap: _togglePlayPause,
          isPlay: !_isPlaying,
        ),
        const SizedBox(width: HollowSpacing.md),
        // Name, slider, timestamps — all left-aligned in one column.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.attachment.fileName,
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: HollowSpacing.xxs),
              // Scrub slider — strip internal padding so the track
              // aligns flush with the text above and below.
              SizedBox(
                height: 20,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor: hollow.accent,
                    inactiveTrackColor: hollow.border,
                    thumbColor: hollow.accent,
                    overlayColor: hollow.accent.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    min: 0,
                    max: durationMs.clamp(1, double.infinity),
                    value: positionMs,
                    onChanged: _onSeek,
                  ),
                ),
              ),
              // Timestamps + file size.
              Row(
                children: [
                  Text(
                    _fmt(_position),
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _fmt(_duration.inMilliseconds > 0
                        ? _duration
                        : Duration(milliseconds: _probedDurationMs ?? 0)),
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    '  ·  ${widget.attachment.formattedSize}',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Helpers ─────────────────────────────────────────────────────

  static String _fmt(Duration d) {
    final mins = d.inMinutes;
    final secs = d.inSeconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  static String _formatDuration(int ms) {
    final totalSec = (ms / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Circular play/pause button with optical centering.
///
/// The play triangle is visually off-center when geometrically centered —
/// nudge it 1px right to optically balance it inside the circle.
class _PlayButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final bool isPlay;
  final String? semanticLabel;

  const _PlayButton({
    required this.icon,
    required this.color,
    this.onTap,
    this.isPlay = true,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    return HollowPressable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Padding(
            // Nudge play icon 1px right for optical centering.
            padding: EdgeInsets.only(left: isPlay ? 1.5 : 0),
            child: Icon(icon, color: Colors.white, size: 16),
          ),
        ),
      ),
    );
  }
}

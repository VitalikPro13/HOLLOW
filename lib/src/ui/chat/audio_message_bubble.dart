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
import 'package:hollow/src/ui/chat/file_card_status.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Renders an audio attachment inline in a message bubble.
///
/// One clip plays at a time, through [currentlyPlayingAudioProvider], and the
/// slot is cross-linked with [currentlyPlayingVideoProvider], so starting one
/// stops the other.
class AudioMessageBubble extends ConsumerStatefulWidget {
  final FileAttachment attachment;

  /// Manual-download hook (issue #41): with no bytes on disk the play button
  /// becomes a download button rather than a dead control.
  final VoidCallback? onDownload;

  /// Why the bytes are not here yet: the caption the meta row carries and what
  /// the leading control does. Defaults to the plain Download button.
  final FileCardStatus status;

  const AudioMessageBubble({
    super.key,
    required this.attachment,
    this.onDownload,
    this.status = const FileCardStatus(control: FileCardControl.download),
  });

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

  /// Pre-play duration in milliseconds, null until a probe succeeds.
  int? _probedDurationMs;

  /// A probe was actually handed to ffmpeg. Only this suppresses the deferred
  /// probe on the play tap.
  bool _probeStarted = false;

  /// The eager path has decided for this file, a refusal included, so the sniff
  /// is not re-run every rebuild and no probe is claimed to have happened.
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
    // diskPath may arrive only once a transfer completes.
    if (!_probeStarted) _maybeProbe();
  }

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  /// True when the attachment is a recorded voice note by every measure we
  /// have, and so may be decoded before the user asks for it.
  ///
  /// The extension that routed it here is the SENDER's choice, so the name
  /// shape and a plausible size have to agree before anything is decoded.
  bool _looksLikeAVoiceNote() => isGenuineVoiceNote(
        // The wire header's `voice` flag does not reach Dart yet; pass it here
        // instead of this literal once it does.
        voice: true,
        name: widget.attachment.fileName,
        ext: widget.attachment.fileExt,
        sizeBytes: widget.attachment.sizeBytes,
      );

  /// The zero-tap probe.
  ///
  /// Probing runs the bundled ffmpeg over bytes a stranger sent, and an
  /// auto-downloaded file arrives with no interaction at all, so the eager path
  /// is kept to the one case that earns it: a small, genuine voice note that
  /// really does open with an Ogg header on disk. Everything else waits for the
  /// play tap, which is the user asking for the decode.
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

    // One decision per file, a refusal included: the bytes will not change
    // under us. The play tap can still probe afterwards.
    _eagerProbeSettled = true;
    if (!await AudioProbeService.looksLikeOgg(path)) return;
    _probeStarted = true;
    await _runProbe(path);
  }

  /// Probes for the duration badge, then prewarms the transcode cache.
  Future<void> _runProbe(String path) async {
    final ms = await AudioProbeService.probeDurationMs(path);
    if (ms != null && mounted) {
      setState(() => _probedDurationMs = ms);
    }
    // Prewarms the Windows Opus to WAV transcode cache, so the first play tap
    // is instant.
    unawaited(
      AudioTranscodeService.ensurePlayable(path).catchError((_) => null),
    );
  }

  /// The on-disk path for this attachment, preferring the persisted one and
  /// falling back to the live transfer state, so the play button enables the
  /// moment a download finishes rather than on the next chat reload.
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

    ref.read(currentlyPlayingAudioProvider.notifier).state = _playKey;
    // Clearing the video slot stops any playing video.
    ref.read(currentlyPlayingVideoProvider.notifier).state = null;

    // The tap is the consent: everything the eager gate held back happens here,
    // in front of a user who asked for it.
    setState(() => _preparing = true);

    if (!_probeStarted) {
      _probeStarted = true;
      final ms = await AudioProbeService.probeDurationMs(path);
      if (!mounted) return;
      if (ms != null) setState(() => _probedDurationMs = ms);
    }

    // Windows' Media Foundation cannot decode Opus-in-Ogg, so an .ogg input
    // goes through the bundled ffmpeg into a cached PCM WAV.
    String? playable;
    try {
      playable = await AudioTranscodeService.ensurePlayable(path);
    } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

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

    final transfer = ref.watch(
      fileTransferProvider.select((s) => s[widget.attachment.fileId]),
    );
    final isComplete =
        widget.attachment.isComplete || (transfer?.isComplete ?? false);
    // The first build after the file lands on disk starts the duration probe.
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

  Widget _buildIdle(HollowTheme hollow, bool isComplete, bool isDownloading, String? vaultPhase, int bytesReceived) {
    final canPlay = _canPlay() && isComplete;
    // Undownloaded and idle: a live download button rather than a dead dimmed
    // play control (issue #41).
    final idle = !canPlay && !isComplete && !isDownloading && vaultPhase == null;
    final control = widget.status.control;
    final showDownload = idle &&
        widget.onDownload != null &&
        (control == FileCardControl.download ||
            control == FileCardControl.retry);
    // A request in flight holds the button's footprint with a spinner and takes
    // no taps; a queued or dead ask has nothing to press and the caption says
    // why.
    final showBusy = idle && control == FileCardControl.busy;
    final showBlocked = idle && control == FileCardControl.none;
    final caption = idle ? widget.status.caption : null;
    final durationText = _probedDurationMs != null
        ? _formatDuration(_probedDurationMs!)
        : null;

    return Row(
      children: [
        if (showBusy || showBlocked)
          _StatusCircle(
            busy: showBusy,
            color: showBusy ? hollow.accent : hollow.elevated,
            iconColor: hollow.textSecondary,
          )
        else if (showDownload)
          _PlayButton(
            icon: LucideIcons.download,
            color: hollow.accent,
            onTap: widget.onDownload,
            isPlay: false,
            semanticLabel: 'Download ${widget.attachment.fileName}',
          )
        else
          _PlayButton(
            // A deferred probe or transcode takes a moment, so the button says
            // so and stops taking taps until it finishes.
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
                  if (durationText != null && caption == null) ...[
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
                  // The caption takes the size line rather than crowding in
                  // beside it.
                  Flexible(
                    child: Text(
                      caption ??
                          (vaultPhase != null
                              ? '$vaultPhase  ${widget.attachment.formattedSize}'
                              : isDownloading && bytesReceived > 0
                                  ? '${_formatBytes(bytesReceived)} / ${widget.attachment.formattedSize}'
                                  : isDownloading
                                      ? 'Downloading... ${widget.attachment.formattedSize}'
                                      : widget.attachment.formattedSize),
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
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
        _PlayButton(
          icon: _isPlaying ? LucideIcons.pause : LucideIcons.play,
          color: hollow.accent,
          onTap: _togglePlayPause,
          isPlay: !_isPlaying,
        ),
        const SizedBox(width: HollowSpacing.md),
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
              // Internal padding stripped, so the track aligns flush with the
              // text above and below.
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

/// The play/download circle's non-interactive twin: a spinner while a request
/// is out, a cloud-off glyph when there is nothing to press. Deliberately not a
/// [HollowPressable], because a control that takes no taps must not be offered
/// to a screen reader as a button.
class _StatusCircle extends StatelessWidget {
  final bool busy;
  final Color color;
  final Color iconColor;

  const _StatusCircle({
    required this.busy,
    required this.color,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(
        child: busy
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                  backgroundColor: Colors.white.withValues(alpha: 0.24),
                ),
              )
            : Icon(LucideIcons.cloudOff, color: iconColor, size: 16),
      ),
    );
  }
}

/// Circular play/pause button. The play triangle reads off-centre when it is
/// geometrically centred, so it is nudged right.
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
            padding: EdgeInsets.only(left: isPlay ? 1.5 : 0),
            child: Icon(icon, color: Colors.white, size: 16),
          ),
        ),
      ),
    );
  }
}

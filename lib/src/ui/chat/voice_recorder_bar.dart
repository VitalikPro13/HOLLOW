import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/services/voice_message_recorder.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Hard ceiling on recording length — mirrors the 34 MB DM file limit vibe.
/// At 24 kbps that's ~366 MB, but no one is actually going to hit this.
const Duration kVoiceMessageMaxDuration = Duration(hours: 34);

/// Inline bar shown in place of the chat input row while recording.
///
/// - Tap mic to start is handled by the parent.
/// - Cancel button discards the file.
/// - Send button stops recording and calls [onFinished] with the result.
class VoiceRecorderBar extends ConsumerStatefulWidget {
  final void Function(VoiceRecordingResult result) onFinished;
  final VoidCallback onCancelled;

  const VoiceRecorderBar({
    super.key,
    required this.onFinished,
    required this.onCancelled,
  });

  @override
  ConsumerState<VoiceRecorderBar> createState() => _VoiceRecorderBarState();
}

class _VoiceRecorderBarState extends ConsumerState<VoiceRecorderBar>
    with SingleTickerProviderStateMixin {
  late final VoiceMessageRecorder _recorder;
  late final AnimationController _pulse;
  StreamSubscription<double>? _ampSub;
  StreamSubscription<Duration>? _elapsedSub;

  final Queue<double> _waveform = Queue<double>();
  static const int _waveformSamples = 48;

  Duration _elapsed = Duration.zero;
  bool _stopping = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _recorder = VoiceMessageRecorder();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (!ReduceMotionController.instance.isReduced) {
      _pulse.repeat(reverse: true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final deviceId = ref.read(audioInputDeviceProvider).valueOrNull;
    try {
      await _recorder.start(preferredDeviceId: deviceId);
      _started = true;
      _ampSub = _recorder.amplitudes.listen((level) {
        if (!mounted) return;
        setState(() {
          _waveform.addLast(level);
          while (_waveform.length > _waveformSamples) {
            _waveform.removeFirst();
          }
        });
      });
      _elapsedSub = _recorder.elapsed.listen((d) {
        if (!mounted) return;
        setState(() => _elapsed = d);
        if (d >= kVoiceMessageMaxDuration) {
          _send();
        }
      });
    } on RecorderPermissionException {
      if (!mounted) return;
      HollowToast.show(
        context,
        'Microphone permission denied',
        type: HollowToastType.error,
      );
      widget.onCancelled();
    } on RecorderFfmpegMissingException {
      if (!mounted) return;
      HollowToast.show(
        context,
        'Voice encoder unavailable',
        type: HollowToastType.error,
      );
      widget.onCancelled();
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        'Failed to start recording: $e',
        type: HollowToastType.error,
      );
      widget.onCancelled();
    }
  }

  @override
  void dispose() {
    _ampSub?.cancel();
    _elapsedSub?.cancel();
    _pulse.dispose();
    // Defensive: if the widget is torn down mid-recording, drop the file.
    if (_started && !_stopping) {
      _recorder.cancel().whenComplete(() => _recorder.dispose());
    } else {
      _recorder.dispose();
    }
    super.dispose();
  }

  Future<void> _cancel() async {
    if (_stopping) return;
    _stopping = true;
    await _ampSub?.cancel();
    await _elapsedSub?.cancel();
    await _recorder.cancel();
    if (!mounted) return;
    widget.onCancelled();
  }

  Future<void> _send() async {
    if (_stopping) return;
    _stopping = true;
    await _ampSub?.cancel();
    await _elapsedSub?.cancel();
    final result = await _recorder.stop();
    if (!mounted) return;
    if (result == null) {
      widget.onCancelled();
      return;
    }
    widget.onFinished(result);
  }

  String _formatElapsed(Duration d) {
    final totalSeconds = d.inSeconds;
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    if (h > 0) return '$h:$mm:$ss';
    return '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Row(
      children: [
        // Cancel (discard).
        HollowPressable(
          onTap: _cancel,
          semanticLabel: 'Discard recording',
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(LucideIcons.trash2,
              color: hollow.error, size: 20),
        ),
        const SizedBox(width: HollowSpacing.xs),

        // Pulsing recording dot + timer + waveform strip.
        Expanded(
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
            ),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusLg),
            ),
            child: Row(
              children: [
                FadeTransition(
                  opacity: Tween<double>(begin: 0.35, end: 1.0)
                      .animate(_pulse),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: hollow.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                SizedBox(
                  width: 48,
                  child: Text(
                    _formatElapsed(_elapsed),
                    style: HollowTypography.mono.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  // Decorative live-amplitude visual — conveys nothing a screen
                  // reader can use (the recording state is carried by the timer
                  // text and the labeled Discard/Send controls). Keep it out of
                  // the semantics tree.
                  child: ExcludeSemantics(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _WaveformPainter(
                          samples: _waveform.toList(growable: false),
                          color: hollow.accent,
                          maxSamples: _waveformSamples,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),

        // Send.
        HollowPressable(
          onTap: _send,
          semanticLabel: 'Send voice message',
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          backgroundColor: hollow.accent,
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(LucideIcons.send,
              color: hollow.textOnAccent, size: 20),
        ),
      ],
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> samples;
  final Color color;
  final int maxSamples;

  static final _paint = Paint()
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 2.0;

  _WaveformPainter({
    required this.samples,
    required this.color,
    required this.maxSamples,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty) return;
    _paint.color = color;

    final slotWidth = size.width / maxSamples;
    final centerY = size.height / 2;
    final startSlot = maxSamples - samples.length;

    for (var i = 0; i < samples.length; i++) {
      final amp = samples[i].clamp(0.0, 1.0);
      final scaled = amp < 0.05 ? 0.05 : amp;
      final barHeight = scaled * size.height * 0.9;
      final x = (startSlot + i) * slotWidth + slotWidth / 2;
      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        _paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) => true;
}

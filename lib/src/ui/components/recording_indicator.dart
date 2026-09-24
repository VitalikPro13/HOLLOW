import 'dart:async';

import 'package:flutter/material.dart';

import 'package:hollow/src/core/reduce_motion.dart';

/// Pulsing red dot and "REC", marking anyone recording the call.
class RecordingIndicator extends StatefulWidget {
  /// If non-null, the elapsed recording time is shown next to "REC".
  final DateTime? startedAt;

  final double dotSize;
  final double fontSize;
  final bool showLabel;

  const RecordingIndicator({
    super.key,
    this.startedAt,
    this.dotSize = 8,
    this.fontSize = 11,
    this.showLabel = true,
  });

  const RecordingIndicator.compact({super.key, this.startedAt})
      : dotSize = 6,
        fontSize = 9,
        showLabel = true;

  /// No text, for use as an overlay badge on an avatar.
  const RecordingIndicator.dotOnly({super.key})
      : startedAt = null,
        dotSize = 8,
        fontSize = 0,
        showLabel = false;

  @override
  State<RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<RecordingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  Timer? _tickTimer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    ReduceMotionController.instance.effective.addListener(_syncPulse);
    _syncPulse();

    if (widget.startedAt != null) {
      _elapsed = DateTime.now().difference(widget.startedAt!);
      _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          _elapsed = DateTime.now().difference(widget.startedAt!);
        });
      });
    }
  }

  @override
  void didUpdateWidget(RecordingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.startedAt != oldWidget.startedAt) {
      _tickTimer?.cancel();
      _tickTimer = null;
      if (widget.startedAt != null) {
        _elapsed = DateTime.now().difference(widget.startedAt!);
        _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          setState(() {
            _elapsed = DateTime.now().difference(widget.startedAt!);
          });
        });
      }
    }
  }

  @override
  void dispose() {
    ReduceMotionController.instance.effective.removeListener(_syncPulse);
    _pulse.dispose();
    _tickTimer?.cancel();
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  /// The dot holds still under Reduce motion, and starts or stops live.
  void _syncPulse() {
    if (ReduceMotionController.instance.isReduced) {
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    const recRed = Color(0xFFE53935);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_pulse),
          child: Container(
            width: widget.dotSize,
            height: widget.dotSize,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: recRed,
              boxShadow: [
                BoxShadow(
                  color: Color(0x88E53935),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
        if (widget.showLabel) ...[
          SizedBox(width: widget.dotSize * 0.6),
          Text(
            widget.startedAt != null
                ? 'REC ${_formatElapsed(_elapsed)}'
                : 'REC',
            style: TextStyle(
              color: recRed,
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

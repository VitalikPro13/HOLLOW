import 'dart:async';

import 'package:flutter/material.dart';

/// Pulsing red dot + "REC" text. Used to mark anyone (self or remote peer)
/// who is currently recording the call. Self version can also show the
/// elapsed recording time next to the label.
class RecordingIndicator extends StatefulWidget {
  /// If non-null, the elapsed recording time is shown next to "REC".
  final DateTime? startedAt;

  /// Override sizes for tighter contexts (e.g. participant row).
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

  /// Compact variant for tight places (participant rows, name tags).
  const RecordingIndicator.compact({super.key, this.startedAt})
      : dotSize = 6,
        fontSize = 9,
        showLabel = true;

  /// Dot-only variant — no text. Useful as an overlay badge on avatars.
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
    )..repeat(reverse: true);

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
              letterSpacing: 0.5,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

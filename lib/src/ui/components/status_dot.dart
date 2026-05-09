import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// A small colored circle indicating connection/encryption status.
///
/// Set [pulse] to true for a breathing glow animation — a soft ring
/// that fades in/out over 3 seconds. All pulsing dots share a single
/// ticker via [SharedTickers.pulse] instead of per-instance controllers.
class StatusDot extends StatelessWidget {
  final Color? color;
  final double size;
  final bool pulse;

  const StatusDot({
    super.key,
    this.color,
    this.size = 8,
    this.pulse = false,
  });

  /// Online status (green) with optional pulse.
  const StatusDot.online({super.key, this.size = 8, this.pulse = false})
      : color = null; // uses success from theme

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dotColor = color ?? hollow.success;

    if (!pulse) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: dotColor,
          shape: BoxShape.circle,
        ),
      );
    }

    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: SharedTickers.instance.pulse,
        builder: (context, value, _) {
          return CustomPaint(
            size: Size(size, size),
            painter: _PulseDotPainter(
              pulseValue: value,
              color: dotColor,
            ),
          );
        },
      ),
    );
  }
}

class _PulseDotPainter extends CustomPainter {
  final double pulseValue;
  final Color color;

  final Paint _dotPaint = Paint();
  final Paint _glowPaint = Paint();

  _PulseDotPainter({required this.pulseValue, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    if (pulseValue > 0) {
      _glowPaint
        ..color = color.withValues(alpha: 0.4 * pulseValue)
        ..maskFilter = ui.MaskFilter.blur(BlurStyle.normal, 3 * pulseValue);
      canvas.drawCircle(center, radius + 1.5 * pulseValue, _glowPaint);
    }

    _dotPaint.color = color;
    canvas.drawCircle(center, radius, _dotPaint);
  }

  @override
  bool shouldRepaint(_PulseDotPainter old) =>
      old.pulseValue != pulseValue || old.color != color;
}

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// A small status indicator (connection / presence / encryption).
///
/// To satisfy "Differentiate Without Color", presence is conveyed by SHAPE as
/// well as color: [filled] true = solid disc (online/active), false = a hollow
/// ring with a transparent center (offline). A screen reader picks up
/// [semanticLabel] when provided.
///
/// Set [pulse] to true for a breathing glow animation — a soft ring that fades
/// in/out over 3 seconds. All pulsing dots share a single ticker via
/// [SharedTickers.pulse] instead of per-instance controllers.
class StatusDot extends StatelessWidget {
  final Color? color;
  final double size;
  final bool pulse;

  /// Solid disc when true (online); hollow ring when false (offline). The
  /// shape difference is the non-color cue.
  final bool filled;

  /// Optional screen-reader label (e.g. "Online" / "Offline").
  final String? semanticLabel;

  const StatusDot({
    super.key,
    this.color,
    this.size = 8,
    this.pulse = false,
    this.filled = true,
    this.semanticLabel,
  });

  /// Online status (green) with optional pulse.
  const StatusDot.online({super.key, this.size = 8, this.pulse = false})
      : color = null, // uses success from theme
        filled = true,
        semanticLabel = 'Online';

  /// Offline status — hollow ring (shape cue), no pulse.
  const StatusDot.offline({super.key, this.size = 8, this.color})
      : pulse = false,
        filled = false,
        semanticLabel = 'Offline';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dotColor = color ?? hollow.success;

    Widget dot;
    if (!pulse) {
      dot = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          // Hollow ring for offline: transparent fill + colored border.
          color: filled ? dotColor : Colors.transparent,
          shape: BoxShape.circle,
          border: filled
              ? null
              : Border.all(color: dotColor, width: size <= 8 ? 1.5 : 2),
        ),
      );
    } else {
      dot = RepaintBoundary(
        child: ValueListenableBuilder<double>(
          valueListenable: SharedTickers.instance.pulse,
          builder: (context, value, _) {
            return CustomPaint(
              size: Size(size, size),
              painter: _PulseDotPainter(
                pulseValue: value,
                color: dotColor,
                filled: filled,
              ),
            );
          },
        ),
      );
    }

    if (semanticLabel != null) {
      return Semantics(label: semanticLabel, child: dot);
    }
    return dot;
  }
}

class _PulseDotPainter extends CustomPainter {
  final double pulseValue;
  final Color color;
  final bool filled;

  final Paint _dotPaint = Paint();
  final Paint _glowPaint = Paint();

  _PulseDotPainter({
    required this.pulseValue,
    required this.color,
    this.filled = true,
  });

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

    if (filled) {
      _dotPaint
        ..color = color
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radius, _dotPaint);
    } else {
      // Hollow ring — shape cue for offline.
      final stroke = size.width <= 8 ? 1.5 : 2.0;
      _dotPaint
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke;
      canvas.drawCircle(center, radius - stroke / 2, _dotPaint);
    }
  }

  @override
  bool shouldRepaint(_PulseDotPainter old) =>
      old.pulseValue != pulseValue ||
      old.color != color ||
      old.filled != filled;
}

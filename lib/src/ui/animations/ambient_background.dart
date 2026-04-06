import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';

/// Very slow-drifting ambient background for the chat area.
///
/// Two soft radial gradient blobs (teal + purple/blue) at low opacity
/// drift in a slow figure-8 pattern over ~45 seconds.
///
/// Uses [SharedTickers.ambient] at ~15fps instead of a 60fps ticker —
/// the motion is so slow that 15fps is visually identical but uses ~75%
/// less CPU.
///
/// When a custom background image is set, blobs are hidden (image is
/// rendered at the shell level behind everything).
class AmbientBackground extends ConsumerWidget {
  final Color color1;
  final Color color2;
  final double opacity;
  final Widget child;

  const AmbientBackground({
    super.key,
    required this.color1,
    required this.color2,
    this.opacity = 0.04,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasCustomBg = ref.watch(backgroundProvider).hasBackground;

    // Skip blobs when custom background is active.
    if (hasCustomBg) return child;

    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: SharedTickers.instance.ambient,
        builder: (context, value, child) {
          final t = value * 2 * math.pi;

          final x1 = 0.5 + 0.25 * math.sin(t);
          final y1 = 0.5 + 0.15 * math.sin(t * 2);

          final x2 = 0.5 - 0.2 * math.sin(t + math.pi * 0.7);
          final y2 = 0.5 - 0.2 * math.sin(t * 2 + math.pi);

          return Stack(
            children: [
              child!,
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _AmbientPainter(
                      color1: color1.withValues(alpha: opacity),
                      color2: color2.withValues(alpha: opacity),
                      center1: Offset(x1, y1),
                      center2: Offset(x2, y2),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: child,
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  final Color color1;
  final Color color2;
  final Offset center1;
  final Offset center2;

  _AmbientPainter({
    required this.color1,
    required this.color2,
    required this.center1,
    required this.center2,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c1 = Offset(center1.dx * size.width, center1.dy * size.height);
    final r1 = size.width * 0.55;
    final paint1 = Paint()
      ..shader = RadialGradient(
        colors: [color1, color1, color1.withValues(alpha: 0)],
        stops: const [0.0, 0.35, 1.0],
      ).createShader(Rect.fromCircle(center: c1, radius: r1));
    canvas.drawCircle(c1, r1, paint1);

    final c2 = Offset(center2.dx * size.width, center2.dy * size.height);
    final r2 = size.width * 0.5;
    final paint2 = Paint()
      ..shader = RadialGradient(
        colors: [color2, color2, color2.withValues(alpha: 0)],
        stops: const [0.0, 0.35, 1.0],
      ).createShader(Rect.fromCircle(center: c2, radius: r2));
    canvas.drawCircle(c2, r2, paint2);
  }

  @override
  bool shouldRepaint(_AmbientPainter oldDelegate) {
    return center1 != oldDelegate.center1 || center2 != oldDelegate.center2;
  }
}

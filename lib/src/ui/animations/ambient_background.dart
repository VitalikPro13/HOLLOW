import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';

/// Very slow-drifting ambient background for the chat area.
///
/// Driven by [SharedTickers.ambient], a shared 30fps timer rather than a
/// per-widget [Ticker], so it costs nothing at all while the blobs are off
/// screen. A custom background image replaces them entirely.
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

    if (hasCustomBg) return child;

    // The blobs and the content are SEPARATE layers on purpose. One boundary
    // around both spares the rebuild but not the raster: a repaint inside a
    // boundary re-rasters the whole boundary, so every blob tick would
    // re-render the largest surface in the app, thirty times a second.
    return Stack(
      children: [
        RepaintBoundary(child: child),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ValueListenableBuilder<double>(
                valueListenable: SharedTickers.instance.ambient,
                builder: (context, value, _) {
                  final t = value * 2 * math.pi;

                  final x1 = 0.5 + 0.25 * math.sin(t);
                  final y1 = 0.5 + 0.15 * math.sin(t * 2);

                  final x2 = 0.5 - 0.2 * math.sin(t + math.pi * 0.7);
                  final y2 = 0.5 - 0.2 * math.sin(t * 2 + math.pi);

                  return CustomPaint(
                    painter: _AmbientPainter(
                      color1: color1.withValues(alpha: opacity),
                      color1Fade: color1.withValues(alpha: 0),
                      color2: color2.withValues(alpha: opacity),
                      color2Fade: color2.withValues(alpha: 0),
                      center1: Offset(x1, y1),
                      center2: Offset(x2, y2),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AmbientPainter extends CustomPainter {
  final Color color1;
  final Color color1Fade;
  final Color color2;
  final Color color2Fade;
  final Offset center1;
  final Offset center2;

  final Paint _paint1 = Paint();
  final Paint _paint2 = Paint();

  _AmbientPainter({
    required this.color1,
    required this.color1Fade,
    required this.color2,
    required this.color2Fade,
    required this.center1,
    required this.center2,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c1 = Offset(center1.dx * size.width, center1.dy * size.height);
    final r1 = size.width * 0.55;
    _paint1.shader = RadialGradient(
      colors: [color1, color1, color1Fade],
      stops: const [0.0, 0.35, 1.0],
    ).createShader(Rect.fromCircle(center: c1, radius: r1));
    canvas.drawCircle(c1, r1, _paint1);

    final c2 = Offset(center2.dx * size.width, center2.dy * size.height);
    final r2 = size.width * 0.5;
    _paint2.shader = RadialGradient(
      colors: [color2, color2, color2Fade],
      stops: const [0.0, 0.35, 1.0],
    ).createShader(Rect.fromCircle(center: c2, radius: r2));
    canvas.drawCircle(c2, r2, _paint2);
  }

  @override
  bool shouldRepaint(_AmbientPainter oldDelegate) {
    return center1 != oldDelegate.center1 || center2 != oldDelegate.center2;
  }
}

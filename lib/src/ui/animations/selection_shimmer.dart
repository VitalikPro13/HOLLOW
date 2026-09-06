import 'package:flutter/material.dart';
import 'package:hollow/src/core/shared_tickers.dart';

/// A subtle shimmer overlay for selected list items, sweeping over 4s on
/// [SharedTickers] rather than a controller of its own.
///
/// [vertical] sweeps top to bottom instead, for voice channels.
class SelectionShimmer extends StatelessWidget {
  final Widget child;
  final Color highlightColor;
  final BorderRadius? borderRadius;
  final bool vertical;

  const SelectionShimmer({
    super.key,
    required this.child,
    required this.highlightColor,
    this.borderRadius,
    this.vertical = false,
  });

  @override
  Widget build(BuildContext context) {
    // The sweep gets its own layer, so a 60fps repaint costs the sweep and not
    // the row under it. Without a boundary between them, markNeedsPaint walks
    // up to whatever layer the list owns and re-rasters all of it every frame.
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: ClipRRect(
                borderRadius: borderRadius ?? BorderRadius.zero,
                child: ValueListenableBuilder<double>(
                  valueListenable: SharedTickers.instance.shimmer,
                  builder: (context, value, _) {
                    return CustomPaint(
                      painter: _ShimmerPainter(
                        position: value * 4.0 - 1.5,
                        highlightColor: highlightColor,
                        vertical: vertical,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  final double position;
  final Color highlightColor;
  final bool vertical;

  final Paint _paint = Paint();

  _ShimmerPainter({
    required this.position,
    required this.highlightColor,
    required this.vertical,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Alignment begin;
    final Alignment end;
    if (vertical) {
      begin = Alignment(0, position - 0.5);
      end = Alignment(0, position + 0.5);
    } else {
      begin = Alignment(position - 0.5, 0);
      end = Alignment(position + 0.5, 0);
    }
    _paint.shader = LinearGradient(
      begin: begin,
      end: end,
      colors: [Colors.transparent, highlightColor, Colors.transparent],
    ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, _paint);
  }

  @override
  bool shouldRepaint(_ShimmerPainter old) => old.position != position;
}

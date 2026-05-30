import 'package:flutter/material.dart';

/// Custom slider track that renders a rainbow hue gradient (0°-360°).
/// Used by the accent color picker on both desktop and mobile.
class RainbowSliderTrackShape extends SliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = true,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 14;
    final trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(
      offset.dx + 8,
      trackTop,
      parentBox.size.width - 16,
      trackHeight,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = true,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
    );

    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));

    final gradient = LinearGradient(
      colors: List.generate(
        13,
        (i) => HSLColor.fromAHSL(1.0, i * 30.0, 0.85, 0.5).toColor(),
      ),
    );

    final paint = Paint()
      ..shader = gradient.createShader(rect);

    context.canvas.drawRRect(rrect, paint);
  }
}

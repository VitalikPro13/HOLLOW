import 'package:flutter/material.dart';

/// An icon with a diagonal cut through it, drawn the way Lucide's `*Off`
/// glyphs are cut.
///
/// Lucide has no `downloadOff`, and a `ban` circle or an `x` reads as "delete"
/// or "error" next to a row of message actions, so the slash is drawn here over
/// any base icon at Lucide's own proportions.
///
/// It reads as a CUT rather than a scribble because a slightly wider stroke in
/// the SURFACE colour goes down first and clears a gap through the glyph, so
/// [backgroundColor] must be whatever the icon sits on.
class SlashedIcon extends StatelessWidget {
  final IconData icon;
  final double size;

  /// The icon's colour. The slash uses it too, so the glyph stays one object.
  final Color color;

  /// The surface behind the icon, painted under the slash so the cut shows.
  final Color backgroundColor;

  const SlashedIcon({
    super.key,
    required this.icon,
    required this.size,
    required this.color,
    required this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(icon, size: size, color: color),
          Positioned.fill(
            child: CustomPaint(
              painter: _SlashPainter(color: color, background: backgroundColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  final Color color;
  final Color background;

  /// Paints are built once per painter, never per frame.
  final Paint _cut;
  final Paint _stroke;

  _SlashPainter({required this.color, required this.background})
      : _cut = Paint()
          ..color = background
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
        _stroke = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    // Lucide draws at a 24 box with a stroke of 2 and its slashes inset by 2.
    final strokeWidth = side * 2 / 24;
    final inset = side * 2.5 / 24;
    final start = Offset(size.width - inset, inset);
    final end = Offset(inset, size.height - inset);

    _cut.strokeWidth = strokeWidth + 1.6;
    _stroke.strokeWidth = strokeWidth;
    canvas.drawLine(start, end, _cut);
    canvas.drawLine(start, end, _stroke);
  }

  @override
  bool shouldRepaint(_SlashPainter old) =>
      old.color != color || old.background != background;
}

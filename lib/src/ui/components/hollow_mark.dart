import 'package:flutter/widgets.dart';

/// The Hollow app logo, the H with the padlock arch and the keyhole, in one
/// flat [color] at [size] tall.
///
/// Drawn from `assets/hollow_icon_foreground.svg`'s geometry: there is no SVG
/// renderer in the app, and the brand mark has no gradient or glow in chrome.
class HollowMark extends StatelessWidget {
  final double size;
  final Color color;

  const HollowMark({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * _kBox.width / _kBox.height,
      height: size,
      child: CustomPaint(painter: _HollowMarkPainter(color)),
    );
  }
}

/// The mark's extent inside the 1000 x 1000 source artboard.
const Rect _kBox = Rect.fromLTRB(260, 220, 740, 780);

class _HollowMarkPainter extends CustomPainter {
  final Color color;
  const _HollowMarkPainter(this.color);

  static final Path _mark = _build();

  static Path _build() {
    const r = Radius.circular(14);
    final body = Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(260, 234)
      ..arcToPoint(const Offset(274, 220), radius: r)
      ..lineTo(324, 220)
      ..arcToPoint(const Offset(338, 234), radius: r)
      ..lineTo(338, 448)
      ..lineTo(400, 448)
      ..lineTo(400, 412)
      ..lineTo(414, 412)
      ..lineTo(414, 335)
      ..arcToPoint(const Offset(586, 335), radius: const Radius.circular(86))
      ..lineTo(586, 412)
      ..lineTo(600, 412)
      ..lineTo(600, 448)
      ..lineTo(662, 448)
      ..lineTo(662, 234)
      ..arcToPoint(const Offset(676, 220), radius: r)
      ..lineTo(726, 220)
      ..arcToPoint(const Offset(740, 234), radius: r)
      ..lineTo(740, 766)
      ..arcToPoint(const Offset(726, 780), radius: r)
      ..lineTo(676, 780)
      ..arcToPoint(const Offset(662, 766), radius: r)
      ..lineTo(662, 536)
      ..lineTo(600, 536)
      ..lineTo(600, 552)
      ..arcToPoint(const Offset(584, 568), radius: const Radius.circular(16))
      ..lineTo(416, 568)
      ..arcToPoint(const Offset(400, 552), radius: const Radius.circular(16))
      ..lineTo(400, 536)
      ..lineTo(338, 536)
      ..lineTo(338, 766)
      ..arcToPoint(const Offset(324, 780), radius: r)
      ..lineTo(274, 780)
      ..arcToPoint(const Offset(260, 766), radius: r)
      ..close()
      // The shackle's hollow.
      ..moveTo(450, 412)
      ..lineTo(450, 335)
      ..arcToPoint(const Offset(550, 335), radius: const Radius.circular(50))
      ..lineTo(550, 412)
      ..close();
    final keyhole = Path()
      ..addOval(Rect.fromCircle(center: const Offset(500, 477), radius: 18))
      ..addRRect(RRect.fromRectAndRadius(
          const Rect.fromLTWH(493, 487, 14, 34), const Radius.circular(4)));
    return Path.combine(PathOperation.difference, body, keyhole)
        .shift(-_kBox.topLeft);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _kBox.width, size.height / _kBox.height);
    canvas.drawPath(_mark, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HollowMarkPainter old) => old.color != color;
}

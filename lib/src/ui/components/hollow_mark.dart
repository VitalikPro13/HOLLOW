import 'package:flutter/widgets.dart';

/// The Hollow app logo, the H with the padlock and its keyhole, in one flat
/// [color] at [size] tall.
///
/// Drawn from `assets/branding/hollow_mark.svg`'s path: there is no SVG
/// renderer in the app, and the brand mark has no gradient or glow in chrome.
class HollowMark extends StatelessWidget {
  final double size;
  final Color color;

  const HollowMark({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * _kSize.width / _kSize.height,
      height: size,
      child: CustomPaint(painter: _HollowMarkPainter(color)),
    );
  }
}

/// The mark's own coordinate space, the SVG's viewBox.
const Size _kSize = Size(548, 620);

class _HollowMarkPainter extends CustomPainter {
  final Color color;
  const _HollowMarkPainter(this.color);

  static final Path _mark = _build();

  static Path _build() {
    const r = Radius.circular(20);
    return Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(0, 20)
      ..arcToPoint(const Offset(20, 0), radius: r)
      ..lineTo(80, 0)
      ..arcToPoint(const Offset(100, 20), radius: r)
      ..lineTo(100, 265)
      ..lineTo(150, 265)
      ..lineTo(150, 238)
      ..arcToPoint(const Offset(170, 218), radius: r)
      ..lineTo(184, 218)
      ..lineTo(184, 130)
      ..arcToPoint(const Offset(364, 130), radius: const Radius.circular(90))
      ..lineTo(364, 218)
      ..lineTo(378, 218)
      ..arcToPoint(const Offset(398, 238), radius: r)
      ..lineTo(398, 265)
      ..lineTo(448, 265)
      ..lineTo(448, 20)
      ..arcToPoint(const Offset(468, 0), radius: r)
      ..lineTo(528, 0)
      ..arcToPoint(const Offset(548, 20), radius: r)
      ..lineTo(548, 600)
      ..arcToPoint(const Offset(528, 620), radius: r)
      ..lineTo(468, 620)
      ..arcToPoint(const Offset(448, 600), radius: r)
      ..lineTo(448, 355)
      ..lineTo(398, 355)
      ..lineTo(398, 382)
      ..arcToPoint(const Offset(378, 402), radius: r)
      ..lineTo(170, 402)
      ..arcToPoint(const Offset(150, 382), radius: r)
      ..lineTo(150, 355)
      ..lineTo(100, 355)
      ..lineTo(100, 600)
      ..arcToPoint(const Offset(80, 620), radius: r)
      ..lineTo(20, 620)
      ..arcToPoint(const Offset(0, 600), radius: r)
      ..close()
      // The shackle's opening.
      ..moveTo(238, 218)
      ..lineTo(238, 130)
      ..arcToPoint(const Offset(310, 130), radius: const Radius.circular(36))
      ..lineTo(310, 218)
      ..close()
      // The keyhole: a round head over a slot, one contour.
      ..moveTo(284, 307.82)
      ..lineTo(284, 332)
      ..arcToPoint(const Offset(264, 332), radius: const Radius.circular(10))
      ..lineTo(264, 307.82)
      ..arcToPoint(const Offset(284, 307.82),
          radius: const Radius.circular(24), largeArc: true)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _kSize.width, size.height / _kSize.height);
    canvas.drawPath(_mark, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HollowMarkPainter old) => old.color != color;
}

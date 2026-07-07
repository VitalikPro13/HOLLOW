import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Platform glyphs for game-card platform chips.
///
/// PlayStation / Linux / Apple / Android come from the bundled SimpleIcons
/// font; Windows, Xbox and Nintendo Switch were REMOVED from Simple Icons
/// (trademark purge), so those three are drawn with CustomPaint. All glyphs
/// are decorative — the chip they sit in carries the text label.
class PlatformIcon extends StatelessWidget {
  final String slug;
  final double size;
  final Color color;

  const PlatformIcon({
    super.key,
    required this.slug,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    switch (slug) {
      case 'pc':
        return _paint(_WindowsPainter(color));
      case 'xbox':
        return _paint(_XboxPainter(color));
      case 'nintendo':
        return _paint(_SwitchPainter(color));
      case 'mac':
      case 'ios':
        return _font(BrandIcons.apple);
      case 'linux':
        return _font(BrandIcons.linux);
      case 'playstation':
        return _font(BrandIcons.playstation);
      case 'android':
        return _font(BrandIcons.android);
      default:
        return _font(LucideIcons.gamepad2);
    }
  }

  Widget _font(IconData icon) => Icon(icon, size: size, color: color);

  Widget _paint(CustomPainter painter) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: painter),
      );
}

/// Human label for a platform slug (chip text, semantics).
String platformLabel(String slug) => switch (slug) {
      'pc' => 'Windows',
      'mac' => 'macOS',
      'linux' => 'Linux',
      'playstation' => 'PlayStation',
      'xbox' => 'Xbox',
      'nintendo' => 'Nintendo',
      'android' => 'Android',
      'ios' => 'iOS',
      _ => slug,
    };

/// The four-pane Windows mark: 2×2 squares with a thin gutter.
class _WindowsPainter extends CustomPainter {
  final Color color;
  const _WindowsPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final paint = Paint()..color = color;
    // Slight inset so the mark doesn't feel heavier than font glyphs.
    final inset = s * 0.06;
    final gap = s * 0.09;
    final pane = (s - inset * 2 - gap) / 2;
    for (final dx in [0, 1]) {
      for (final dy in [0, 1]) {
        canvas.drawRect(
          Rect.fromLTWH(
            inset + dx * (pane + gap),
            inset + dy * (pane + gap),
            pane,
            pane,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_WindowsPainter old) => old.color != color;
}

/// The Xbox sphere: a filled circle with an X carved out of it.
class _XboxPainter extends CustomPainter {
  final Color color;
  const _XboxPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(s / 2, s / 2);
    final r = s * 0.46;
    final rect = Offset.zero & size;

    // Carving needs its own layer so BlendMode.clear cuts the sphere, not
    // whatever the icon is drawn over.
    canvas.saveLayer(rect, Paint());
    canvas.drawCircle(c, r, Paint()..color = color);

    final carve = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.14
      ..strokeCap = StrokeCap.round;
    // The X's strokes bow slightly outward, like the real mark.
    final k = r * 0.62; // reach of each diagonal
    final bow = s * 0.10;
    final d1 = Path()
      ..moveTo(c.dx - k, c.dy - k)
      ..quadraticBezierTo(c.dx + bow, c.dy - bow, c.dx + k, c.dy + k);
    final d2 = Path()
      ..moveTo(c.dx + k, c.dy - k)
      ..quadraticBezierTo(c.dx - bow, c.dy - bow, c.dx - k, c.dy + k);
    canvas.drawPath(d1, carve);
    canvas.drawPath(d2, carve);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_XboxPainter old) => old.color != color;
}

/// The Nintendo Switch mark: outlined left Joy-Con with a dot, filled right
/// Joy-Con with a carved dot.
class _SwitchPainter extends CustomPainter {
  final Color color;
  const _SwitchPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final rect = Offset.zero & size;
    final top = s * 0.06;
    final bottom = s * 0.94;
    final gap = s * 0.08;
    final halfW = s * 0.38;
    final left = (s - halfW * 2 - gap) / 2;
    final corner = Radius.circular(s * 0.24);

    // Left Joy-Con: stroked, rounded on its outer (left) side.
    final stroke = s * 0.10;
    final leftRect = RRect.fromRectAndCorners(
      Rect.fromLTRB(
        left + stroke / 2,
        top + stroke / 2,
        left + halfW - stroke / 2,
        bottom - stroke / 2,
      ),
      topLeft: corner,
      bottomLeft: corner,
    );
    canvas.drawRRect(
      leftRect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    canvas.drawCircle(
      Offset(left + halfW * 0.52, s * 0.32),
      s * 0.075,
      Paint()..color = color,
    );

    // Right Joy-Con: filled, rounded on its outer (right) side, dot carved.
    final rightLeft = left + halfW + gap;
    canvas.saveLayer(rect, Paint());
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTRB(rightLeft, top, rightLeft + halfW, bottom),
        topRight: corner,
        bottomRight: corner,
      ),
      Paint()..color = color,
    );
    canvas.drawCircle(
      Offset(rightLeft + halfW * 0.52, s * 0.62),
      s * 0.075,
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SwitchPainter old) => old.color != color;
}

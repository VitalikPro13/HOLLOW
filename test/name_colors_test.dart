import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

List<Color> _surfaces(HollowTheme t) =>
    [t.background, t.surface, t.elevated, t.overlay, t.hover];

double _hueGap(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  final ids = List.generate(200, (i) => '12D3KooWpeer${i * 7919}');

  test('the hash is fixed, so a name keeps its colour across platforms', () {
    expect(stableHash(''), 0x811c9dc5);
    expect(stableHash('a'), 0xe40c292c);
    expect(stableHash('foobar'), 0xbf9cf968);
  });

  for (final hue in [null, 0.0, 90.0, 173.0, 260.0, 330.0]) {
    for (final dark in [true, false]) {
      final t = hue == null
          ? (dark ? HollowTheme.dark() : HollowTheme.light())
          : (dark
              ? HollowTheme.darkWithHue(hue)
              : HollowTheme.lightWithHue(hue));
      final label = '${dark ? 'dark' : 'light'}, accent hue ${hue ?? 'default'}';
      final accentHue = HSLColor.fromColor(t.accent).hue;

      test('names clear contrast on every surface ($label)', () {
        final min = dark ? 7.0 : 5.0;
        for (final id in ids) {
          final c = nameColorFor(id, t);
          for (final bg in _surfaces(t)) {
            expect(Contrast.ratio(c, bg), greaterThanOrEqualTo(min - 0.01),
                reason: '$id on $bg');
          }
        }
      });

      test('no name lands in the accent band ($label)', () {
        for (final id in ids) {
          final h = HSLColor.fromColor(nameColorFor(id, t)).hue;
          expect(_hueGap(h, accentHue), greaterThanOrEqualTo(kNameAccentBand - 1),
              reason: id);
        }
      });
    }
  }

  test('names spread across the spectrum', () {
    final t = HollowTheme.dark();
    final buckets = <int>{};
    for (final id in ids) {
      buckets.add(HSLColor.fromColor(nameColorFor(id, t)).hue ~/ 30);
    }
    expect(buckets.length, greaterThanOrEqualTo(9));
  });
}

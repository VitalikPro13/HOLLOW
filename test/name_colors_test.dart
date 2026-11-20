import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/settings/name_color_editor.dart';

List<Color> _surfaces(HollowTheme t) =>
    [t.background, t.surface, t.elevated, t.overlay, t.hover];

double _hueGap(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// The gradient's colour at [t], 0..1, blended the way [LinearGradient] does.
Color _sample(NamePaint p, double t) {
  final colors = p.gradientColors;
  final at = p.gradientPositions ??
      [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)];
  if (t <= at.first) return colors.first;
  for (var i = 1; i < colors.length; i++) {
    if (t <= at[i]) {
      final span = at[i] - at[i - 1];
      if (span == 0) return colors[i];
      return Color.lerp(colors[i - 1], colors[i], (t - at[i - 1]) / span)!;
    }
  }
  return colors.last;
}

/// The name's gradient as drawn: one row of [width] pixels through its shader.
Future<List<Color>> _render(NamePaint p, {int width = 240}) async {
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), 1);
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(rect, Paint()..shader = p.shader(rect));
  final image = await recorder.endRecording().toImage(width, 1);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return [
    for (var x = 0; x < width; x++)
      Color.fromARGB(255, bytes.getUint8(x * 4), bytes.getUint8(x * 4 + 1),
          bytes.getUint8(x * 4 + 2)), // design-ignore: a rendered test pixel
  ];
}

/// The colours among [samples] whose hue lands in the accent band; colours too
/// grey to have a hue do not count.
List<String> _inBand(Iterable<Color> samples, double accentHue,
    {double slack = 0}) {
  final hits = <String>[];
  for (final c in samples) {
    final r = c.r, g = c.g, b = c.b;
    final chroma = [r, g, b].reduce((x, y) => x > y ? x : y) -
        [r, g, b].reduce((x, y) => x < y ? x : y);
    if (chroma < 0.06) continue;
    final gap = _hueGap(HSLColor.fromColor(c).hue, accentHue);
    if (gap < kNameAccentBand - slack) {
      hits.add('${c.toARGB32().toRadixString(16)} at ${gap.toStringAsFixed(1)}');
    }
  }
  return hits;
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

  // -- #140: a person's own name colour ------------------------------------

  group('chosen name colours', () {
    test('the field reads only the version 1 grammar', () {
      expect(nameColorStops('1:ff8800'), [const Color(0xffff8800)]); // design-ignore: test fixture colour
      expect(nameColorStops('1:ff8800,00aaff,7755ff')?.length, 3);
      for (final bad in [
        '', '1:', '1:FF8800', '1:ff880', '1:ff8800,', '2:anything', 'ff8800',
        '1:ff8800,00aaff,7755ff,000000', '1: ff8800',
      ]) {
        expect(nameColorStops(bad), isNull, reason: bad);
      }
      final stops = [
        const Color(0xff123456), // design-ignore: test fixture colour
        const Color(0x80abcdef), // design-ignore: test fixture colour, alpha dropped
      ];
      expect(nameColorField(stops), '1:123456,abcdef');
      expect(nameColorStops(nameColorField(stops))?.first,
          const Color(0xff123456)); // design-ignore: test fixture colour
    });

    test('no field is the hashed colour', () {
      final t = HollowTheme.dark();
      expect(namePaintFor('12D3KooWx', t).stops, [nameColorFor('12D3KooWx', t)]);
      expect(namePaintFor('12D3KooWx', t, field: '2:later').stops,
          [nameColorFor('12D3KooWx', t)]);
      expect(chosenNamePaint(t, ''), isNull);
    });

    // #140, Rong-Yao: a picked #C92222 showed as #F49D9D (pink) on dark.
    test('a picked red stays red on dark and exact on light', () {
      const red = Color(0xffc92222); // design-ignore: the reporter's pick
      final field = nameColorField([red]);
      final dark = HollowTheme.dark();
      final shown = namePaintFor('x', dark, field: field).color;
      final hsl = HSLColor.fromColor(shown);
      final picked = HSLColor.fromColor(red);
      expect(_hueGap(hsl.hue, picked.hue), lessThan(1));
      expect((hsl.saturation - picked.saturation).abs(), lessThan(0.02));
      // Lifted only as far as the floor needs, nowhere near the pink.
      final worst = _surfaces(dark)
          .map((bg) => Contrast.ratio(shown, bg))
          .reduce((a, b) => a < b ? a : b);
      expect(worst, inInclusiveRange(kChosenNameContrast, kChosenNameContrast + 0.1));
      expect(hsl.lightness, lessThan(0.67));
      expect(shown, isNot(const Color(0xfff49d9d))); // design-ignore: the reported pink
      // The swatch they picked was the preset red of 0.14.1, which became
      // exactly #F49D9D on dark at the old floor and #C71616 on light.
      final preset = nameColorField([const Color(0xffe83030)]); // design-ignore: the 0.14.1 preset red
      final presetDark = namePaintFor('x', dark, field: preset).color;
      expect(presetDark, isNot(const Color(0xfff49d9d))); // design-ignore: the reported pink
      expect(HSLColor.fromColor(presetDark).lightness, lessThan(0.7));
      expect(_hueGap(HSLColor.fromColor(presetDark).hue, 0), lessThan(1));
      final light = HollowTheme.light();
      expect(namePaintFor('x', light, field: field).color, red);
      expect(namePaintFor('x', light, field: field, self: true).color, red);
    });

    // A selected row lays the accent-muted fill under the name. Lifting every
    // chosen colour for that fill would turn a red pink everywhere, so only
    // the selected row lifts it, and only as far as that fill needs.
    test('a picked red is lifted on a selected row only', () {
      const red = Color(0xffc92222); // design-ignore: the reporter's pick
      for (final t in [HollowTheme.dark(), HollowTheme.light()]) {
        final plain = namePaintFor('x', t, field: nameColorField([red]));
        final selected = namePaintOnSelected(plain, t);
        final worst = selectedNameSurfaces(t)
            .map((bg) => Contrast.ratio(selected.color, bg))
            .reduce((a, b) => a < b ? a : b);
        expect(worst, inInclusiveRange(kChosenNameContrast, kChosenNameContrast + 0.1));
        final hsl = HSLColor.fromColor(selected.color);
        expect(_hueGap(hsl.hue, 0), lessThan(1));
        expect((hsl.saturation - HSLColor.fromColor(red).saturation).abs(),
            lessThan(0.02));
      }
      // Off the selected row the red keeps the plain floor's tone: the lift
      // never reaches the chat.
      final dark = HollowTheme.dark();
      final chat = namePaintFor('x', dark, field: nameColorField([red])).color;
      expect(HSLColor.fromColor(chat).lightness, lessThan(0.67));
    });

    // Reviewer case (UI review, Nov 20): every hue the editor offers, on the
    // selected fill over each surface.
    for (final (label, t) in [
      ('dark', HollowTheme.dark()),
      ('light', HollowTheme.light()),
      ('dark, accent 0', HollowTheme.darkWithHue(0)),
      ('light, accent 200', HollowTheme.lightWithHue(200)),
    ]) {
      test('a chosen name on a selected row clears 4.5:1 on the fill ($label)',
          () {
        for (var h = 0.0; h < 360; h += 5) {
          for (final self in [false, true]) {
            final shown = namePaintOnSelected(
                namePaintFor('x', t,
                    field: nameColorField([nameColorFromHue(h)]), self: self),
                t);
            for (final stop in shown.gradientColors) {
              for (final bg in selectedNameSurfaces(t)) {
                expect(Contrast.ratio(stop, bg),
                    greaterThanOrEqualTo(kChosenNameContrast - 0.01),
                    reason: 'hue $h self $self: $stop on $bg');
              }
            }
          }
        }
      });
    }

    test('each preset swatch still looks like itself on both themes', () {
      for (final t in [HollowTheme.dark(), HollowTheme.light()]) {
        final shown = <HSLColor>[];
        for (final h in kNameColorPresetHues) {
          final pick = nameColorFromHue(h);
          final c = HSLColor.fromColor(
              namePaintFor('x', t, field: nameColorField([pick]), self: true)
                  .color);
          expect(_hueGap(c.hue, h), lessThan(2), reason: 'hue $h');
          expect(c.saturation, greaterThanOrEqualTo(0.85), reason: 'hue $h');
          // Neither washed out to a pastel nor sunk to a near-black.
          expect(c.lightness, inInclusiveRange(0.22, 0.75), reason: 'hue $h');
          shown.add(c);
        }
        // Ten swatches, ten different hues as drawn.
        for (var i = 0; i < shown.length; i++) {
          for (var j = i + 1; j < shown.length; j++) {
            expect(_hueGap(shown[i].hue, shown[j].hue), greaterThan(15));
          }
        }
      }
    });

    final hues = [for (var h = 0.0; h < 360; h += 15) h];
    for (final dark in [true, false]) {
      for (final accent in [null, 0.0, 200.0]) {
        final t = accent == null
            ? (dark ? HollowTheme.dark() : HollowTheme.light())
            : (dark
                ? HollowTheme.darkWithHue(accent)
                : HollowTheme.lightWithHue(accent));
        final label = '${dark ? 'dark' : 'light'}, accent ${accent ?? 'default'}';

        test('every chosen stop clears the name floor ($label)', () {
          const min = kChosenNameContrast;
          final picks = [
            for (final h in hues) HSLColor.fromAHSL(1, h, 0.8, 0.55).toColor(),
            const Color(0xff000000), // design-ignore: worst-case pick
            const Color(0xffffffff), // design-ignore: worst-case pick
            const Color(0xff0000ff), // design-ignore: worst-case pick
            const Color(0xffffff00), // design-ignore: worst-case pick
          ];
          for (var i = 0; i + 2 < picks.length; i += 3) {
            final paint = namePaintFor('x', t,
                field: nameColorField(picks.sublist(i, i + 3)));
            expect(paint.stops, hasLength(3));
            for (final stop in paint.stops) {
              for (final bg in _surfaces(t)) {
                expect(Contrast.ratio(stop, bg),
                    greaterThanOrEqualTo(min - 0.01),
                    reason: '$stop on $bg');
              }
            }
          }
        });

        test('your own chosen colour keeps its hue ($label)', () {
          for (final h in hues) {
            final pick = HSLColor.fromAHSL(1, h, 0.8, 0.55).toColor();
            final shown = namePaintFor('x', t,
                    field: nameColorField([pick]), self: true)
                .color;
            final shownHsl = HSLColor.fromColor(shown);
            // Near white or black the hue is barely defined; skip those.
            if (shownHsl.lightness > 0.95 || shownHsl.lightness < 0.05) continue;
            expect(_hueGap(shownHsl.hue, h), lessThan(3), reason: 'hue $h');
          }
        });
      }
    }

    // Accent impersonation: only the viewer's own name may wear the accent.
    for (final dark in [true, false]) {
      for (final accent in [null, 0.0, 200.0, 350.0]) {
        final t = accent == null
            ? (dark ? HollowTheme.dark() : HollowTheme.light())
            : (dark
                ? HollowTheme.darkWithHue(accent)
                : HollowTheme.lightWithHue(accent));
        final a = HSLColor.fromColor(t.accent).hue;
        final label = '${dark ? 'dark' : 'light'}, accent ${accent ?? 'default'}';

        test('someone else in the accent band turns to its edge ($label)', () {
          for (var d = -34.0; d <= 34; d += 2) {
            final h = (a + d + 360) % 360;
            final pick = HSLColor.fromAHSL(1, h, 0.8, 0.55).toColor();
            final field = nameColorField([pick]);
            final shown = HSLColor.fromColor(namePaintFor('x', t, field: field).color);
            final gap = _hueGap(shown.hue, a);
            expect(gap, greaterThanOrEqualTo(kNameAccentBand - 3),
                reason: 'offset $d landed $gap from the accent');
            expect(gap, lessThan(kNameAccentBand + 3), reason: 'just outside, offset $d');
            // The nearest side: the turn never crosses the accent.
            final side = (shown.hue - a + 540) % 360 - 180;
            if (d != 0) expect(side.sign, d.sign, reason: 'offset $d');
            expect((shown.saturation - 0.8).abs(), lessThan(0.08), reason: 'saturation kept');
            // The same pick is yours to wear.
            final own = HSLColor.fromColor(
                namePaintFor('x', t, field: field, self: true).color);
            expect(_hueGap(own.hue, h), lessThan(3), reason: 'own, offset $d');
            expect(chosenNamePaint(t, field)!.color, namePaintFor('x', t, field: field).color);
          }
        });
      }
    }

    test('a gradient turns only the stops in the accent band', () {
      final t = HollowTheme.dark();
      final a = HSLColor.fromColor(t.accent).hue;
      final teal = HSLColor.fromAHSL(1, a, 0.8, 0.55).toColor();
      final red = HSLColor.fromAHSL(1, (a + 180) % 360, 0.8, 0.55).toColor();
      final field = nameColorField([red, teal]);
      final theirs = namePaintFor('x', t, field: field).stops;
      final mine = namePaintFor('x', t, field: field, self: true).stops;
      expect(theirs.first, mine.first, reason: 'a stop outside the band is untouched');
      expect(_hueGap(HSLColor.fromColor(mine.last).hue, a), lessThan(3));
      expect(_hueGap(HSLColor.fromColor(theirs.last).hue, a),
          greaterThanOrEqualTo(kNameAccentBand - 3));
    });

    // A gradient blends in RGB: two stops either side of the band can pass
    // through the accent between them although neither is in it.
    for (final dark in [true, false]) {
      for (final accentIn in [0.0, 90.0, 220.0, 330.0]) {
        final t = dark
            ? HollowTheme.darkWithHue(accentIn)
            : HollowTheme.lightWithHue(accentIn);
        final a = HSLColor.fromColor(t.accent).hue;
        final label = '${dark ? 'dark' : 'light'}, accent $accentIn';
        Color at(double offset) =>
            HSLColor.fromAHSL(1, (a + offset + 360) % 360, 1, 0.5).toColor();

        test('someone else\'s gradient never blends through the accent, as drawn ($label)',
            () async {
          for (final picks in [
            [at(-40), at(40)],
            [at(40), at(-40)],
            [at(-80), at(10), at(90)],
            [at(-120), at(60), at(-60)],
          ]) {
            final field = nameColorField(picks);
            final theirs = namePaintFor('x', t, field: field);
            expect(_inBand(await _render(theirs), a, slack: 3), isEmpty,
                reason: '$field shows the accent');
            expect(theirs.stops, hasLength(picks.length),
                reason: 'the chosen stops stay as chosen');
            // Your own keeps the plain blend, accent and all.
            final mine = namePaintFor('x', t, field: field, self: true);
            expect(mine.gradientPositions, isNull);
            expect(mine.gradientColors, mine.stops);
          }
        });

        test('no pair of stops blends through the accent ($label)', () {
          for (var h1 = 0.0; h1 < 360; h1 += 15) {
            for (var h2 = 0.0; h2 < 360; h2 += 15) {
              final field = nameColorField([
                HSLColor.fromAHSL(1, h1, 0.9, 0.5).toColor(),
                HSLColor.fromAHSL(1, h2, 0.9, 0.5).toColor(),
              ]);
              final p = namePaintFor('x', t, field: field);
              final samples = [for (var i = 0; i <= 200; i++) _sample(p, i / 200)];
              expect(_inBand(samples, a, slack: 3), isEmpty,
                  reason: '$field, hues $h1 and $h2');
            }
          }
        });
      }
    }

    test('a blend that stays clear of the accent is left alone', () {
      final t = HollowTheme.darkWithHue(220);
      final a = HSLColor.fromColor(t.accent).hue;
      Color at(double offset) =>
          HSLColor.fromAHSL(1, (a + offset + 360) % 360, 1, 0.5).toColor();
      // One side of the accent; then either side, but blending the far way round.
      for (final picks in [
        [at(60), at(150)],
        [at(40), at(120)],
        [at(-120), at(-40)],
        [at(-100), at(100)],
        [at(-150), at(-40), at(170)],
      ]) {
        final p = namePaintFor('x', t, field: nameColorField(picks));
        expect(p.gradientPositions, isNull, reason: '$picks');
        expect(p.gradientColors, p.stops);
      }
    });

    test('the paint is cached on the raw field, parsed once', () {
      final t = HollowTheme.dark();
      final a = namePaintFor('x', t, field: '1:ff8800,00aaff');
      expect(identical(namePaintFor('y', t, field: '1:ff8800,00aaff'), a), isTrue);
      expect(identical(namePaintFor('x', t, field: '2:later'),
          namePaintFor('x', t, field: '2:later')), isTrue);
      expect(namePaintFor('x', t, field: '2:later').stops, [nameColorFor('x', t)]);
      expect(identical(namePaintFor('x', t, field: '1:ff8800,00aaff', self: true), a),
          isFalse, reason: 'yours is cached apart');
    });
  });
}


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// Dev-time WCAG guard: fails CI if a core token pairing regresses below
/// threshold. Body text wants 4.5:1; large/UI elements want 3:1.
void main() {
  const bodyMin = 4.5;
  const uiMin = 3.0;

  void expectRatio(String label, Color fg, Color bg, double min) {
    final r = Contrast.ratio(fg, bg);
    expect(r, greaterThanOrEqualTo(min),
        reason: '$label contrast $r is below $min:1');
  }

  group('dark theme contrast', () {
    final t = HollowTheme.dark();
    test('text on surfaces clears body threshold', () {
      for (final bg in [t.background, t.surface, t.elevated]) {
        expectRatio('textPrimary', t.textPrimary, bg, bodyMin);
        expectRatio('textSecondary', t.textSecondary, bg, bodyMin);
        expectRatio('textTertiary', t.textTertiary, bg, bodyMin);
      }
    });
    test('accentText legible as foreground on background', () {
      expectRatio('accentText', t.accentText, t.background, bodyMin);
    });
    test('text on accent fill', () {
      expectRatio('textOnAccent', t.textOnAccent, t.accent, uiMin);
    });
  });

  group('light theme contrast', () {
    final t = HollowTheme.light();
    test('text on surfaces clears body threshold', () {
      for (final bg in [t.background, t.surface, t.elevated]) {
        expectRatio('textPrimary', t.textPrimary, bg, bodyMin);
        expectRatio('textSecondary', t.textSecondary, bg, bodyMin);
        expectRatio('textTertiary', t.textTertiary, bg, bodyMin);
      }
    });
    test('accentText + semantics legible on light background', () {
      expectRatio('accentText', t.accentText, t.background, bodyMin);
      expectRatio('error', t.error, t.background, uiMin);
      expectRatio('success', t.success, t.background, uiMin);
      expectRatio('warning', t.warning, t.background, uiMin);
    });
  });

  group('ghost and outline button labels', () {
    // These two variants draw their label in the accent, and they are almost
    // every button in the app. Drawn in the RAW accent the label was 2.33:1 on
    // the light theme's white; accentText is the contrast-corrected token and
    // is what they must keep using, on every custom hue as well.
    test('clear body threshold on both themes and every hue', () {
      for (final t in [HollowTheme.dark(), HollowTheme.light()]) {
        for (final bg in [t.background, t.surface, t.elevated]) {
          expectRatio('ghost label', t.accentText, bg, bodyMin);
        }
      }
      for (final hue in [0.0, 60.0, 120.0, 200.0, 240.0, 270.0, 300.0, 330.0]) {
        expectRatio('ghost label dark@$hue', HollowTheme.darkWithHue(hue).accentText,
            HollowTheme.darkWithHue(hue).background, bodyMin);
        expectRatio('ghost label light@$hue',
            HollowTheme.lightWithHue(hue).accentText,
            HollowTheme.lightWithHue(hue).background, bodyMin);
      }
    });

    test('the raw accent is a fill and is NOT safe as a light-theme label', () {
      // The bug this guards: if someone "simplifies" accentText back to accent,
      // this is the number they would be shipping.
      final t = HollowTheme.light();
      expect(Contrast.ratio(t.accent, t.background), lessThan(bodyMin));
    });
  });

  group('custom accent hues stay legible as foreground', () {
    // Worst offenders are low-luminance hues (deep blue ~240, purple ~270,
    // red ~0). ensureContrast must lift/lower them to clear threshold.
    for (final hue in [0.0, 60.0, 120.0, 200.0, 240.0, 270.0, 300.0, 330.0]) {
      test('dark hue $hue accentText ≥ 4.5:1', () {
        final t = HollowTheme.darkWithHue(hue);
        expectRatio('accentText@$hue', t.accentText, t.background, bodyMin);
      });
      test('light hue $hue accentText ≥ 4.5:1', () {
        final t = HollowTheme.lightWithHue(hue);
        expectRatio('accentText@$hue', t.accentText, t.background, bodyMin);
      });
    }
  });
}

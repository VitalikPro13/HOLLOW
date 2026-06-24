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

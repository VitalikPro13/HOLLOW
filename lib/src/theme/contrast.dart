import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show HSLColor;

/// WCAG 2.x contrast utilities, used to keep foreground colours legible on
/// their background and by the test that guards the palette from regressions.
abstract final class Contrast {
  /// Relative luminance per WCAG 2.x (sRGB → linearized).
  static double relativeLuminance(Color c) {
    // Color channels (c.r/g/b) are already 0..1 in modern dart:ui.
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4) as double;

    final r = channel(c.r);
    final g = channel(c.g);
    final b = channel(c.b);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  /// WCAG contrast ratio between two colors (1.0 .. 21.0). Order-independent.
  static double ratio(Color a, Color b) {
    final la = relativeLuminance(a);
    final lb = relativeLuminance(b);
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Returns [foreground] adjusted in lightness until it clears [targetRatio]
  /// against [background], preserving hue and saturation. This is what keeps a
  /// user-chosen accent legible as text whatever hue they pick.
  static Color ensureContrast(
    Color foreground,
    Color background, {
    double targetRatio = 3.0,
  }) {
    if (ratio(foreground, background) >= targetRatio) return foreground;

    final hsl = HSLColor.fromColor(foreground);
    final bgLum = relativeLuminance(background);
    final goUp = bgLum < 0.5;

    var best = foreground;
    // Binary-search the lightness for the minimal change that clears target.
    var lo = goUp ? hsl.lightness : 0.0;
    var hi = goUp ? 1.0 : hsl.lightness;
    for (var i = 0; i < 18; i++) {
      final mid = (lo + hi) / 2;
      final candidate = hsl.withLightness(mid).toColor();
      if (ratio(candidate, background) >= targetRatio) {
        best = candidate;
        if (goUp) {
          hi = mid;
        } else {
          lo = mid;
        }
      } else {
        if (goUp) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
    }
    return best;
  }
}

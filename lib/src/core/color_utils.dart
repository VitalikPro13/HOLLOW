import 'dart:ui' show Color;
import 'package:flutter/painting.dart' show HSLColor;

import '../theme/contrast.dart';
import '../theme/hollow_theme.dart';

final _avatarColorCache = <String, Color>{};
final _nameColorCache = <String, Color>{};

Color colorFromId(String id) {
  return _avatarColorCache[id] ??= _compute(id, 0.5, 0.45);
}

/// Hues this close to the accent are never handed out, so only your own name
/// reads as the accent.
const double kNameAccentBand = 35;

/// A person's name colour, the same on every screen and every platform.
///
/// Pass the MASTER identity, or one person's devices get different colours.
/// The hue skips [kNameAccentBand] on each side of the current accent; the
/// tone clears 7:1 on every dark surface and 5:1 on every light one.
Color nameColorFor(String identity, HollowTheme hollow) {
  final accentHue = HSLColor.fromColor(hollow.accent).hue;
  final dark = Contrast.relativeLuminance(hollow.background) < 0.5;
  final key = '$identity|${hollow.accent.toARGB32()}|$dark';
  return _nameColorCache[key] ??= _nameColor(identity, hollow, accentHue, dark);
}

Color _nameColor(
    String identity, HollowTheme hollow, double accentHue, bool dark) {
  const arc = 360 - 2 * kNameAccentBand;
  final offset = stableHash(identity) % 1000 / 1000 * arc;
  final hue = (accentHue + kNameAccentBand + offset) % 360;
  return Contrast.ensureContrastOnAll(
    HSLColor.fromAHSL(1.0, hue, 0.7, 0.5).toColor(),
    [
      hollow.surface,
      hollow.background,
      hollow.elevated,
      hollow.overlay,
      hollow.hover,
    ],
    targetRatio: dark ? 7.0 : 5.0,
  );
}

/// FNV-1a over the UTF-16 code units: unlike [String.hashCode] it is the same
/// on every platform and every release.
int stableHash(String s) {
  var h = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    h ^= unit;
    // The prime is 2^24 + 0x193, split so no product passes 2^53 on the web.
    h = (((h & 0xff) << 24) + h * 0x193) & 0xffffffff;
  }
  return h;
}

Color _compute(String id, double saturation, double lightness) {
  final hue = (id.hashCode % 360).abs().toDouble();
  return HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor();
}

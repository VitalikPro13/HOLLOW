import 'dart:ui' show Color, Rect, Shader;

import 'package:flutter/foundation.dart' show immutable, listEquals;
import 'package:flutter/painting.dart' show HSLColor, LinearGradient; // design-ignore: the gradient a person chose for their name, content not decoration

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

/// How a person's name is painted: one colour, or a gradient across the name
/// when it has two or three stops.
@immutable
class NamePaint {
  /// The colours the person chose, as shown here. Never empty.
  final List<Color> stops;
  final List<Color>? _drawn;
  final List<double>? _at;

  const NamePaint(this.stops)
      : _drawn = null,
        _at = null;

  const NamePaint._skipping(this.stops, List<Color> drawn, List<double> at)
      : _drawn = drawn,
        _at = at;

  /// The one colour for a surface that cannot draw a gradient (a speaking ring,
  /// the stream overlay): the first stop.
  Color get color => stops.first;

  bool get isGradient => stops.length > 1;

  /// What the gradient draws: [stops], plus a step past the accent band between
  /// two stops whose blend would cross it ([gradientPositions] then non-null).
  List<Color> get gradientColors => _drawn ?? stops;

  /// Where [gradientColors] sit across the name, null = evenly spaced.
  List<double>? get gradientPositions => _at;

  /// Left to right across [bounds], the name's own box.
  Shader shader(Rect bounds) =>
      LinearGradient(colors: gradientColors, stops: _at) // design-ignore: the gradient a person chose for their name
          .createShader(bounds);

  @override
  bool operator ==(Object other) =>
      other is NamePaint &&
      listEquals(other.stops, stops) &&
      listEquals(other._drawn, _drawn) &&
      listEquals(other._at, _at);

  @override
  int get hashCode => Object.hash(
      Object.hashAll(stops),
      _drawn == null ? null : Object.hashAll(_drawn),
      _at == null ? null : Object.hashAll(_at));
}

/// Most stops a chosen name colour holds.
const int kMaxNameColorStops = 3;

final _hexStop = RegExp(r'^[0-9a-f]{6}$');

/// The stops of a person's own name colour field, or null when there is none.
///
/// Version 1 is `1:` and one to three lowercase `rrggbb` stops; Rust's receive
/// gate (`node::name_color`) stores nothing else but '', so a field this cannot
/// read falls back to the hashed colour.
List<Color>? nameColorStops(String field) {
  if (!field.startsWith('1:')) return null;
  final parts = field.substring(2).split(',');
  if (parts.length > kMaxNameColorStops) return null;
  final stops = <Color>[];
  for (final part in parts) {
    if (!_hexStop.hasMatch(part)) return null;
    stops.add(Color(0xff000000 | int.parse(part, radix: 16))); // design-ignore: a colour a person chose, read from their profile
  }
  return stops;
}

/// The version 1 field for [stops] (one to three; alpha is dropped).
String nameColorField(List<Color> stops) {
  assert(stops.isNotEmpty && stops.length <= kMaxNameColorStops);
  String hex(Color c) =>
      (c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0');
  return '1:${stops.map(hex).join(',')}';
}

final _hashedPaintCache = <String, NamePaint>{};
// Keyed on the raw field, so a cache hit never parses; null = not version 1.
final _chosenCache = <String, NamePaint?>{};

/// THE helper for painting a person's name. [field] is their own chosen name
/// colour (pass '' when custom colours are switched off, or for a surface that
/// shows only hashed colours); without one this is [nameColorFor].
///
/// A chosen colour keeps its hue and saturation, and its lightness moves only
/// until every stop clears [kChosenNameContrast] on every surface (a selected
/// row takes [namePaintOnSelected] on top). Unless
/// [self] (the viewer's own name), a stop whose hue sits within
/// [kNameAccentBand] of the accent turns to the nearest edge of the band
/// first, and a blend between two stops that would pass through the band
/// steps across it instead: only your own name may wear the accent.
NamePaint namePaintFor(String identity, HollowTheme hollow,
    {String field = '', bool self = false}) {
  if (field.isNotEmpty) {
    final chosen = _chosenPaint(hollow, field, self);
    if (chosen != null) return chosen;
  }
  final key = '$identity|${hollow.accent.toARGB32()}|'
      '${hollow.background.toARGB32()}';
  return _hashedPaintCache[key] ??=
      NamePaint([nameColorFor(identity, hollow)]);
}

/// The chosen paint only, or null when [field] holds no colour: for surfaces
/// that stay neutral unless the person picked one (member lists, the profile).
NamePaint? chosenNamePaint(HollowTheme hollow, String field,
        {bool self = false}) =>
    field.isEmpty ? null : _chosenPaint(hollow, field, self);

NamePaint? _chosenPaint(HollowTheme hollow, String field, bool self) {
  final key = '$field|$self|${hollow.accent.toARGB32()}|'
      '${hollow.background.toARGB32()}|${hollow.surface.toARGB32()}|'
      '${hollow.elevated.toARGB32()}|${hollow.overlay.toARGB32()}|'
      '${hollow.hover.toARGB32()}';
  if (_chosenCache.containsKey(key)) return _chosenCache[key];
  final picked = nameColorStops(field);
  if (picked == null) return _chosenCache[key] = null;
  final accentHue = HSLColor.fromColor(hollow.accent).hue;
  final stops = [
    for (final stop in picked)
      _readableChosen(self ? stop : _outsideAccentBand(stop, accentHue), hollow),
  ];
  return _chosenCache[key] =
      self ? NamePaint(stops) : _skipAccentBand(stops, accentHue, hollow);
}

/// Hue of [c] relative to the accent, -180..180.
double _accentGap(Color c, double accentHue) =>
    (HSLColor.fromColor(c).hue - accentHue + 540) % 360 - 180;

/// [stops] (each already outside the band) as a gradient that never shows the
/// accent. A gradient blends in RGB, so the hues between two stops follow the
/// short way round the colour wheel; where that way passes the accent, the pair
/// blends from each stop up to its own edge of the band and steps across it at
/// their midpoint. Going the long way round instead would paint hues nobody
/// picked, and one colour for the pair would drop a stop they did pick.
NamePaint _skipAccentBand(
    List<Color> stops, double accentHue, HollowTheme hollow) {
  if (stops.length < 2) return NamePaint(stops);
  final drawn = <Color>[];
  final at = <double>[];
  var skipped = false;
  for (var i = 0; i < stops.length; i++) {
    final pos = i / (stops.length - 1);
    drawn.add(stops[i]);
    at.add(pos);
    if (i + 1 == stops.length) break;
    final a = _accentGap(stops[i], accentHue);
    final b = _accentGap(stops[i + 1], accentHue);
    // Opposite sides, and the short way between them runs through the accent.
    if (a.sign == b.sign || a.abs() + b.abs() >= 180) continue;
    final mid = (i + 0.5) / (stops.length - 1);
    for (final (stop, side) in [(stops[i], a.sign), (stops[i + 1], b.sign)]) {
      final edge = HSLColor.fromColor(stop)
          .withHue((accentHue + side * kNameAccentBand + 360) % 360)
          .toColor();
      drawn.add(_readableChosen(edge, hollow));
      at.add(mid);
    }
    skipped = true;
  }
  return skipped ? NamePaint._skipping(stops, drawn, at) : NamePaint(stops);
}

/// [c] with its hue turned to the nearest edge of the accent band when it sits
/// inside it; saturation and lightness kept.
Color _outsideAccentBand(Color c, double accentHue) {
  final hsl = HSLColor.fromColor(c);
  final gap = (hsl.hue - accentHue + 540) % 360 - 180; // signed, -180..180
  if (gap.abs() >= kNameAccentBand) return c;
  final side = gap < 0 ? -1 : 1;
  return hsl.withHue((accentHue + side * kNameAccentBand + 360) % 360).toColor();
}

/// The contrast a chosen name colour clears on every surface a name sits on,
/// selected fills included: the design language's floor for all text. The
/// hashed colours sit higher so they read as pastels; a chosen colour held
/// that high loses its tone (red goes pink).
const double kChosenNameContrast = 4.5;

List<Color> _surfaces(HollowTheme hollow) => [
      hollow.surface,
      hollow.background,
      hollow.elevated,
      hollow.overlay,
      hollow.hover,
    ];

/// A selected row or chip on each surface: the accent-muted fill laid over it.
List<Color> selectedNameSurfaces(HollowTheme hollow) => [
      for (final s in _surfaces(hollow)) Color.alphaBlend(hollow.accentMuted, s)
    ];

final _selectedCache = <(NamePaint, int, int), NamePaint>{};

/// [paint] for a name on a selected row or chip, lifted until it clears
/// [kChosenNameContrast] on [selectedNameSurfaces] too. Only there: a red
/// clearing a teal-tinted fill turns pink, and everywhere else it stays red.
NamePaint namePaintOnSelected(NamePaint paint, HollowTheme hollow) {
  final key = (paint, hollow.accentMuted.toARGB32(), hollow.background.toARGB32());
  final hit = _selectedCache[key];
  if (hit != null) return hit;
  final fills = selectedNameSurfaces(hollow);
  Color lift(Color c) => Contrast.ensureContrastOnAll(c, fills,
      targetRatio: kChosenNameContrast);
  final stops = [for (final c in paint.stops) lift(c)];
  final drawn = paint._drawn;
  final lifted = drawn == null
      ? NamePaint(stops)
      : NamePaint._skipping(stops, [for (final c in drawn) lift(c)], paint._at!);
  if (_selectedCache.length >= 256) _selectedCache.clear();
  return _selectedCache[key] = lifted;
}

Color _readable(Color c, HollowTheme hollow, bool dark) =>
    Contrast.ensureContrastOnAll(c, _surfaces(hollow),
        targetRatio: dark ? 7.0 : 5.0);

Color _readableChosen(Color c, HollowTheme hollow) =>
    Contrast.ensureContrastOnAll(c, _surfaces(hollow),
        targetRatio: kChosenNameContrast);

Color _nameColor(
    String identity, HollowTheme hollow, double accentHue, bool dark) {
  const arc = 360 - 2 * kNameAccentBand;
  final offset = stableHash(identity) % 1000 / 1000 * arc;
  final hue = (accentHue + kNameAccentBand + offset) % 360;
  return _readable(HSLColor.fromAHSL(1.0, hue, 0.7, 0.5).toColor(), hollow, dark);
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
  final hue = (stableHash(id) % 360).toDouble();
  return HSLColor.fromAHSL(1.0, hue, saturation, lightness).toColor();
}

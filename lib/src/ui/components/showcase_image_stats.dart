import 'dart:typed_data';
import 'dart:ui' as ui;

/// One-shot pixel statistics for a company logo on the game card, computed at
/// render time from the replicated bytes. They decide legibility only (a tint
/// or a plate for the mark), never a colour for the card around it.
class ShowcaseImageStats {
  /// True when nearly all opaque pixels share one ink, as a wordmark logo does.
  final bool isMonochrome;

  /// True when a meaningful share of the canvas is transparent, so the mark is
  /// INK on nothing. Only these may be tinted or plated: an srcIn tint on a
  /// fully opaque image paints the whole rectangle one colour.
  final bool hasTransparency;

  /// Mean sRGB luminance (0..1) of opaque pixels.
  final double avgLuminance;

  const ShowcaseImageStats({
    required this.isMonochrome,
    this.hasTransparency = false,
    required this.avgLuminance,
  });

  static const neutral = ShowcaseImageStats(
    isMonochrome: false,
    avgLuminance: 0.5,
  );
}

/// Cheap content key: FNV-1a over strided samples + length. Cosmetic cache
/// only: a collision merely treats one logo like another.
int _contentKey(Uint8List bytes) {
  var hash = 0x811C9DC5;
  final stride = bytes.length > 4096 ? bytes.length ~/ 4096 : 1;
  for (var i = 0; i < bytes.length; i += stride) {
    hash = ((hash ^ bytes[i]) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash ^ bytes.length;
}

final Map<int, Future<ShowcaseImageStats>> _statsCache = {};

/// Compute (or return cached) stats for one image's bytes. Never throws:
/// undecodable bytes yield [ShowcaseImageStats.neutral].
Future<ShowcaseImageStats> showcaseImageStats(Uint8List bytes) {
  if (bytes.isEmpty) return Future.value(ShowcaseImageStats.neutral);
  // A card touches a handful of logos; reset rather than LRU-churn.
  if (_statsCache.length > 128) _statsCache.clear();
  return _statsCache.putIfAbsent(_contentKey(bytes), () => _compute(bytes));
}

Future<ShowcaseImageStats> _compute(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 40);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    codec.dispose();
    if (data == null) return ShowcaseImageStats.neutral;
    return _fromRgba(data.buffer.asUint8List());
  } catch (_) {
    return ShowcaseImageStats.neutral;
  }
}

ShowcaseImageStats _fromRgba(Uint8List rgba) {
  var total = 0;
  var opaque = 0;
  var monoish = 0;
  var lumSum = 0.0;

  for (var i = 0; i + 3 < rgba.length; i += 4) {
    total++;
    if (rgba[i + 3] < 128) continue; // transparent, not part of the mark
    opaque++;
    final r = rgba[i] / 255.0, g = rgba[i + 1] / 255.0, b = rgba[i + 2] / 255.0;
    final hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final chroma = hi - lo;
    lumSum += 0.2126 * r + 0.7152 * g + 0.0722 * b;
    final sat = hi > 0 ? chroma / hi : 0.0;
    if (sat < 0.18 || chroma < 0.1) monoish++;
  }

  if (opaque == 0) return ShowcaseImageStats.neutral;
  return ShowcaseImageStats(
    isMonochrome: monoish / opaque >= 0.92,
    hasTransparency: total > 0 && (total - opaque) / total >= 0.05,
    avgLuminance: lumSum / opaque,
  );
}

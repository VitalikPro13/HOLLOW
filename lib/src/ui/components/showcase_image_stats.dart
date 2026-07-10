import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// One-shot pixel statistics for showcase images, computed at RENDER time
/// from the replicated bytes (no wire change — existing boards get the same
/// treatment as fresh bakes).
///
/// Two consumers on the game card:
///  - covers/key art → [accent], the game's dominant vibrant color, used to
///    tint washes/borders/gradients (never raw text — callers run any
///    text/icon use through `Contrast.ensureContrast`);
///  - company logos → [isMonochrome] (single-ink wordmarks get re-tinted to
///    the theme text color so black-on-transparent logos survive dark mode)
///    and [avgLuminance] (colorful logos too close to the panel's own
///    luminance get a subtle plate behind them).
class ShowcaseImageStats {
  /// Dominant vibrant color, lightness-clamped to a usable mid range.
  /// Null when the image is effectively colorless (caller keeps the theme
  /// accent).
  final Color? accent;

  /// True when ~all opaque pixels share one ink (saturation ≈ 0 spread) —
  /// the classic black/white wordmark logo.
  final bool isMonochrome;

  /// True when a meaningful share of the canvas is transparent — the mark
  /// is drawn as INK on nothing. Tinting/plating only makes sense for these;
  /// a fully opaque image carries its own background (an srcIn tint on one
  /// paints the entire rectangle a single color — the "white slab" bug).
  final bool hasTransparency;

  /// Mean sRGB luminance (0..1) of opaque pixels.
  final double avgLuminance;

  const ShowcaseImageStats({
    this.accent,
    required this.isMonochrome,
    this.hasTransparency = false,
    required this.avgLuminance,
  });

  static const neutral = ShowcaseImageStats(isMonochrome: false, avgLuminance: 0.5);
}

/// Cheap content key: FNV-1a over strided samples + length. Cosmetic cache
/// only — a collision merely tints with the wrong color.
int _contentKey(Uint8List bytes) {
  // 32-bit FNV-1a (web-safe ints).
  var hash = 0x811C9DC5;
  final stride = bytes.length > 4096 ? bytes.length ~/ 4096 : 1;
  for (var i = 0; i < bytes.length; i += stride) {
    hash = ((hash ^ bytes[i]) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash ^ bytes.length;
}

final Map<int, Future<ShowcaseImageStats>> _statsCache = {};

/// Compute (or return cached) stats for one image's bytes. Never throws —
/// undecodable bytes yield [ShowcaseImageStats.neutral].
Future<ShowcaseImageStats> showcaseImageStats(Uint8List bytes) {
  if (bytes.isEmpty) return Future.value(ShowcaseImageStats.neutral);
  // Unbounded growth guard: a profile dialog session touches a few dozen
  // images at most; reset rather than LRU-churn.
  if (_statsCache.length > 128) _statsCache.clear();
  return _statsCache.putIfAbsent(_contentKey(bytes), () => _compute(bytes));
}

Future<ShowcaseImageStats> _compute(Uint8List bytes) async {
  try {
    // A 40px-wide thumbnail is plenty for color statistics.
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 40);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
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
  // 30°-hue buckets of "vibrant" pixels; the winning bucket's weighted mean
  // becomes the accent.
  final bucketWeight = List.filled(12, 0.0);
  final bucketR = List.filled(12, 0.0);
  final bucketG = List.filled(12, 0.0);
  final bucketB = List.filled(12, 0.0);
  var vibrantWeight = 0.0;

  for (var i = 0; i + 3 < rgba.length; i += 4) {
    total++;
    if (rgba[i + 3] < 128) continue; // transparent — not part of the mark
    opaque++;
    final r = rgba[i] / 255.0, g = rgba[i + 1] / 255.0, b = rgba[i + 2] / 255.0;
    final hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final chroma = hi - lo;
    lumSum += 0.2126 * r + 0.7152 * g + 0.0722 * b;

    final sat = hi > 0 ? chroma / hi : 0.0;
    if (sat < 0.18 || chroma < 0.1) monoish++;

    // Vibrancy: saturated and neither near-black nor blown-out.
    if (sat >= 0.25 && hi >= 0.15 && lo <= 0.95) {
      double hue;
      if (chroma == 0) {
        hue = 0;
      } else if (hi == r) {
        hue = ((g - b) / chroma) % 6;
      } else if (hi == g) {
        hue = (b - r) / chroma + 2;
      } else {
        hue = (r - g) / chroma + 4;
      }
      final bucket = ((hue < 0 ? hue + 6 : hue) * 2).floor().clamp(0, 11);
      final w = sat * hi;
      bucketWeight[bucket] += w;
      bucketR[bucket] += r * w;
      bucketG[bucket] += g * w;
      bucketB[bucket] += b * w;
      vibrantWeight += w;
    }
  }

  if (opaque == 0) return ShowcaseImageStats.neutral;
  final avgLum = lumSum / opaque;
  final isMono = monoish / opaque >= 0.92;

  Color? accent;
  // Require a real colorful presence (≥3% of opaque mass) — a grey screenshot
  // with three red pixels should not turn the card red.
  if (!isMono && vibrantWeight >= opaque * 0.03) {
    var best = 0;
    for (var i = 1; i < 12; i++) {
      if (bucketWeight[i] > bucketWeight[best]) best = i;
    }
    final w = bucketWeight[best];
    if (w > 0) {
      final raw = Color.from(
        alpha: 1.0,
        red: (bucketR[best] / w).clamp(0.0, 1.0),
        green: (bucketG[best] / w).clamp(0.0, 1.0),
        blue: (bucketB[best] / w).clamp(0.0, 1.0),
      );
      // Pull into a usable mid range: never near-black/near-white washes,
      // keep enough saturation to read as "this game's color".
      final hsl = HSLColor.fromColor(raw);
      accent = hsl
          .withLightness(hsl.lightness.clamp(0.35, 0.62))
          .withSaturation(hsl.saturation.clamp(0.45, 0.85))
          .toColor();
    }
  }

  return ShowcaseImageStats(
    accent: accent,
    isMonochrome: isMono,
    hasTransparency: total > 0 && (total - opaque) / total >= 0.05,
    avgLuminance: avgLum,
  );
}

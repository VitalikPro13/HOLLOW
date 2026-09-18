import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'hollow_colors.dart';

/// Emoji fallback for platforms whose system font is stale or absent: Windows
/// 10 stops at Emoji ~12 and a bare Linux install may ship no colour emoji font
/// at all, so both fall back to the bundled Noto Color Emoji. The primary font
/// still wins every glyph it has, and null means the engine's own fallback.
final List<String>? kEmojiFontFallback =
    !kIsWeb && (Platform.isWindows || Platform.isLinux)
        ? const ['NotoColorEmoji']
        : null;

/// Hollow typography: Onest for the interface, Geist Mono for the console
/// voice (ids, hashes, versions), both bundled variable fonts so the app reads
/// the same on every OS. Every style defaults to textPrimary; override the
/// colour with copyWith, never the size.
abstract final class HollowTypography {
  static const sansFamily = 'Onest';
  static const monoFamily = 'GeistMono';

  static final _base = TextStyle(
    fontFamily: sansFamily,
    fontFamilyFallback: kEmojiFontFallback,
    color: HollowColors.textPrimary,
    height: 1.4,
    letterSpacing: 0,
  );

  static final display = _base.copyWith(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );

  static final heading = _base.copyWith(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static final subheading = _base.copyWith(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  static final body = _base.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w400,
  );

  static final bodySmall = _base.copyWith(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: HollowColors.textSecondary,
  );

  static final label = _base.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w500,
  );

  static final caption = _base.copyWith(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: HollowColors.textSecondary,
  );

  /// The smallest role there is: badge text, counters, the tightest chrome.
  /// Below this the text fails the legibility floor, so there is no role for
  /// 9 or 8.
  static final micro = _base.copyWith(
    fontSize: 10,
    fontWeight: FontWeight.w500,
    color: HollowColors.textSecondary,
  );

  static final mono = _base.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    fontFamily: monoFamily,
  );

  /// The console voice in metadata: ids and hashes beside a timestamp.
  static final monoSmall = _base.copyWith(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    fontFamily: monoFamily,
    color: HollowColors.textSecondary,
  );
}

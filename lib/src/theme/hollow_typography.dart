import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'hollow_colors.dart';

/// Emoji fallback for Windows and Linux, whose system emoji font is stale or
/// absent; the primary font still wins every glyph it has, and null means the
/// engine's own fallback.
final List<String>? kEmojiFontFallback = kIsWeb
    ? null
    : emojiFontFallbackFor(
        windows: Platform.isWindows,
        linux: Platform.isLinux,
      );

/// Noto is a bitmap font, and the Windows renderer shrinks its one large strike
/// with visible jaggies; it cannot draw the vector COLRv1 build at all (#104).
/// So Windows' own vector Segoe UI Emoji goes first, behind a flags-only Noto
/// because Segoe draws a flag as two letters; Noto last catches what Segoe
/// lacks, and a combined emoji newer than Windows 10's Segoe may split.
@visibleForTesting
List<String>? emojiFontFallbackFor({required bool windows, required bool linux}) {
  if (windows) {
    return const ['NotoColorEmojiFlags', 'Segoe UI Emoji', 'NotoColorEmoji'];
  }
  return linux ? const ['NotoColorEmoji'] : null;
}

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

  /// Message text on a phone: one step up from [body], because a phone is read
  /// at arm's length and a desktop at the width of a keyboard.
  static final bodyTouch = _base.copyWith(
    fontSize: 16,
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

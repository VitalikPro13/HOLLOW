import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'hollow_colors.dart';

/// Emoji font fallback for platforms with stale/absent system emoji fonts:
/// Windows 10's Segoe UI Emoji stops at Emoji ~12 (newer emoji render as
/// tofu boxes) and bare Linux installs may ship no color emoji font at all,
/// so those platforms fall back to the bundled Noto Color Emoji (declared
/// in pubspec.yaml). The primary font still wins for every glyph it has —
/// only characters it lacks (i.e. emoji) reach Noto. macOS/iOS/Android keep
/// their native, up-to-date emoji fonts. Null = engine default fallback.
final List<String>? kEmojiFontFallback =
    !kIsWeb && (Platform.isWindows || Platform.isLinux)
        ? const ['NotoColorEmoji']
        : null;

/// Hollow typography scale.
///
/// Uses the system font stack for native feel on each platform.
/// All styles default to textPrimary color — override via copyWith where needed.
abstract final class HollowTypography {
  static final _base = TextStyle(
    fontFamily: null, // System default (Segoe UI on Windows, SF Pro on macOS, etc.)
    fontFamilyFallback: kEmojiFontFallback,
    color: HollowColors.textPrimary,
    height: 1.4,
    letterSpacing: 0,
  );

  /// Display — large headings (server name, onboarding titles)
  static final display = _base.copyWith(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1.2,
  );

  /// Heading — section headers
  static final heading = _base.copyWith(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  /// Subheading — panel titles, dialog headers
  static final subheading = _base.copyWith(
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  /// Body — default text
  static final body = _base.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w400,
  );

  /// Body small — secondary text, timestamps
  static final bodySmall = _base.copyWith(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: HollowColors.textSecondary,
  );

  /// Label — buttons, badges, chips
  static final label = _base.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w500,
  );

  /// Caption — tiny text, metadata
  static final caption = _base.copyWith(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: HollowColors.textSecondary,
  );

  /// Mono — peer IDs, code, technical strings
  static final mono = _base.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    fontFamily: 'Consolas', // Falls back to monospace on other platforms
    letterSpacing: 0.5,
  );
}

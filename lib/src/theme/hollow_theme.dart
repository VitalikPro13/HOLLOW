import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'contrast.dart';
import 'hollow_colors.dart';
import 'hollow_spacing.dart';

/// Hollow's custom theme extension — travels with ThemeData.
///
/// Access via: `Theme.of(context).extension<HollowTheme>()!`
/// or the convenience: `HollowTheme.of(context)`
class HollowTheme extends ThemeExtension<HollowTheme> {
  final Color background;
  final Color surface;
  final Color elevated;
  final Color accent;
  final Color accentHover;
  final Color accentMuted;
  /// Accent guaranteed legible as FOREGROUND (text/icons/links) on
  /// [background] — clears ~4.5:1. Use this anywhere accent is text/icon;
  /// keep raw [accent] for fills (which pair with dark [textOnAccent]).
  final Color accentText;
  /// Keyboard-focus ring color (a11y 2.6). Accent auto-adjusted to clear the
  /// WCAG non-text-contrast minimum (~3:1) against [background], so the focus
  /// indicator stays visible on every surface and custom accent hue. Drawn
  /// ONLY on keyboard/assistive-tech focus — never on mouse hover/press.
  final Color focusRing;
  final Color textPrimary;
  final Color textSecondary;
  /// Faded-metadata token (timestamps, "(edited)", counters) that still
  /// clears 4.5:1 — replaces ad-hoc alpha-faded textSecondary.
  final Color textTertiary;
  final Color textOnAccent;
  final Color border;
  final Color error;
  final Color success;
  final Color warning;
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;

  const HollowTheme({
    required this.background,
    required this.surface,
    required this.elevated,
    required this.accent,
    required this.accentHover,
    required this.accentMuted,
    required this.accentText,
    required this.focusRing,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textOnAccent,
    required this.border,
    required this.error,
    required this.success,
    required this.warning,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusXl,
  });

  /// Default dark theme.
  factory HollowTheme.dark() => HollowTheme(
        background: HollowColors.background,
        surface: HollowColors.surface,
        elevated: HollowColors.elevated,
        accent: HollowColors.accent,
        accentHover: HollowColors.accentHover,
        accentMuted: HollowColors.accentMuted,
        accentText: Contrast.ensureContrast(
            HollowColors.accent, HollowColors.background,
            targetRatio: 4.5),
        focusRing: Contrast.ensureContrast(
            HollowColors.accent, HollowColors.background,
            targetRatio: 3.0),
        textPrimary: HollowColors.textPrimary,
        textSecondary: HollowColors.textSecondary,
        textTertiary: HollowColors.textTertiary,
        textOnAccent: HollowColors.textOnAccent,
        border: HollowColors.border,
        error: HollowColors.error,
        success: HollowColors.success,
        warning: HollowColors.warning,
        radiusSm: HollowRadius.sm,
        radiusMd: HollowRadius.md,
        radiusLg: HollowRadius.lg,
        radiusXl: HollowRadius.xl,
      );

  /// Light theme.
  factory HollowTheme.light() => const HollowTheme(
        background: HollowColors.backgroundLight,
        surface: HollowColors.surfaceLight,
        elevated: HollowColors.elevatedLight,
        accent: HollowColors.accent,
        accentHover: HollowColors.accentHover,
        accentMuted: HollowColors.accentMutedLight,
        accentText: HollowColors.accentTextLight,
        // Light-theme focus ring: the dark-on-teal accent is too light on white
        // (~2.3:1) to ring against it; reuse the legible foreground variant
        // (accentTextLight, 5.32:1 — comfortably past the 3:1 ring floor).
        focusRing: HollowColors.accentTextLight,
        textPrimary: HollowColors.textPrimaryLight,
        textSecondary: HollowColors.textSecondaryLight,
        textTertiary: HollowColors.textTertiaryLight,
        textOnAccent: HollowColors.textOnAccentLight,
        border: HollowColors.borderLight,
        error: HollowColors.errorLight,
        success: HollowColors.successLight,
        warning: HollowColors.warningLight,
        radiusSm: HollowRadius.sm,
        radiusMd: HollowRadius.md,
        radiusLg: HollowRadius.lg,
        radiusXl: HollowRadius.xl,
      );

  /// Dark theme with custom accent hue.
  factory HollowTheme.darkWithHue(double hue) => HollowTheme(
        background: HollowColors.background,
        surface: HollowColors.surface,
        elevated: HollowColors.elevated,
        accent: accentFromHue(hue),
        accentHover: accentHoverFromHue(hue),
        accentMuted: accentMutedFromHue(hue),
        accentText: Contrast.ensureContrast(
            accentFromHue(hue), HollowColors.background,
            targetRatio: 4.5),
        focusRing: Contrast.ensureContrast(
            accentFromHue(hue), HollowColors.background,
            targetRatio: 3.0),
        textPrimary: HollowColors.textPrimary,
        textSecondary: HollowColors.textSecondary,
        textTertiary: HollowColors.textTertiary,
        textOnAccent: HollowColors.textOnAccent,
        border: HollowColors.border,
        error: HollowColors.error,
        success: HollowColors.success,
        warning: HollowColors.warning,
        radiusSm: HollowRadius.sm,
        radiusMd: HollowRadius.md,
        radiusLg: HollowRadius.lg,
        radiusXl: HollowRadius.xl,
      );

  /// Light theme with custom accent hue.
  factory HollowTheme.lightWithHue(double hue) => HollowTheme(
        background: HollowColors.backgroundLight,
        surface: HollowColors.surfaceLight,
        elevated: HollowColors.elevatedLight,
        accent: accentFromHue(hue),
        accentHover: accentHoverFromHue(hue),
        accentMuted: accentMutedLightFromHue(hue),
        accentText: Contrast.ensureContrast(
            accentFromHue(hue), HollowColors.backgroundLight,
            targetRatio: 4.5),
        focusRing: Contrast.ensureContrast(
            accentFromHue(hue), HollowColors.backgroundLight,
            targetRatio: 3.0),
        textPrimary: HollowColors.textPrimaryLight,
        textSecondary: HollowColors.textSecondaryLight,
        textTertiary: HollowColors.textTertiaryLight,
        textOnAccent: HollowColors.textOnAccentLight,
        border: HollowColors.borderLight,
        error: HollowColors.errorLight,
        success: HollowColors.successLight,
        warning: HollowColors.warningLight,
        radiusSm: HollowRadius.sm,
        radiusMd: HollowRadius.md,
        radiusLg: HollowRadius.lg,
        radiusXl: HollowRadius.xl,
      );

  /// Returns a copy with semi-transparent panel backgrounds for custom background images.
  /// [opacity] is 0.0 (fully transparent) to 1.0 (fully opaque).
  HollowTheme withPanelOpacity(double opacity) {
    return copyWith(
      background: background.withValues(alpha: opacity),
      surface: surface.withValues(alpha: opacity),
      elevated: elevated.withValues(alpha: opacity),
    );
  }

  /// Returns the background color with full opacity (for bars that should stay opaque).
  Color get opaqueBackground => background.withValues(alpha: 1.0);

  /// Convenience accessor.
  static HollowTheme of(BuildContext context) =>
      Theme.of(context).extension<HollowTheme>()!;

  @override
  HollowTheme copyWith({
    Color? background,
    Color? surface,
    Color? elevated,
    Color? accent,
    Color? accentHover,
    Color? accentMuted,
    Color? accentText,
    Color? focusRing,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textOnAccent,
    Color? border,
    Color? error,
    Color? success,
    Color? warning,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? radiusXl,
  }) {
    return HollowTheme(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      elevated: elevated ?? this.elevated,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      accentMuted: accentMuted ?? this.accentMuted,
      accentText: accentText ?? this.accentText,
      focusRing: focusRing ?? this.focusRing,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textOnAccent: textOnAccent ?? this.textOnAccent,
      border: border ?? this.border,
      error: error ?? this.error,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
      radiusXl: radiusXl ?? this.radiusXl,
    );
  }

  @override
  HollowTheme lerp(covariant HollowTheme? other, double t) {
    if (other == null) return this;
    return HollowTheme(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      elevated: Color.lerp(elevated, other.elevated, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textOnAccent: Color.lerp(textOnAccent, other.textOnAccent, t)!,
      border: Color.lerp(border, other.border, t)!,
      error: Color.lerp(error, other.error, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      radiusSm: radiusSm + (other.radiusSm - radiusSm) * t,
      radiusMd: radiusMd + (other.radiusMd - radiusMd) * t,
      radiusLg: radiusLg + (other.radiusLg - radiusLg) * t,
      radiusXl: radiusXl + (other.radiusXl - radiusXl) * t,
    );
  }
}

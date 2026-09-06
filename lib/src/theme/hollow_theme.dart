import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'contrast.dart';
import 'hollow_colors.dart';
import 'hollow_spacing.dart';

/// Hollow's custom theme extension, travelling with ThemeData. Reach it
/// through [HollowTheme.of].
class HollowTheme extends ThemeExtension<HollowTheme> {
  final Color background;
  final Color surface;
  final Color elevated;
  final Color accent;
  final Color accentHover;
  final Color accentMuted;
  /// The accent as FOREGROUND, clearing ~4.5:1 on [background]. Use it wherever
  /// accent is text or an icon; raw [accent] is for fills only.
  final Color accentText;
  /// Keyboard-focus ring (a11y 2.6): the accent adjusted to clear ~3:1 against
  /// [background], so the indicator survives every custom hue. Drawn ONLY on
  /// keyboard or assistive-tech focus, never on hover or press.
  final Color focusRing;
  final Color textPrimary;
  final Color textSecondary;
  /// The faded-metadata token that still clears 4.5:1, in place of an
  /// alpha-faded textSecondary.
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

  factory HollowTheme.light() => const HollowTheme(
        background: HollowColors.backgroundLight,
        surface: HollowColors.surfaceLight,
        elevated: HollowColors.elevatedLight,
        accent: HollowColors.accent,
        accentHover: HollowColors.accentHover,
        accentMuted: HollowColors.accentMutedLight,
        accentText: HollowColors.accentTextLight,
        // The accent is ~2.3:1 on white, too light to ring against it, so the
        // legible foreground variant carries the focus ring here.
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

  /// Returns a copy with semi-transparent panels, for a custom background
  /// image. [opacity] runs 0.0 (clear) to 1.0 (opaque).
  HollowTheme withPanelOpacity(double opacity) {
    return copyWith(
      background: background.withValues(alpha: opacity),
      surface: surface.withValues(alpha: opacity),
      elevated: elevated.withValues(alpha: opacity),
    );
  }

  /// The background at full opacity, for bars that must stay opaque.
  Color get opaqueBackground => background.withValues(alpha: 1.0);

  /// Background for a notice strip tinted by [tint].
  ///
  /// A bare `tint.withValues(alpha: …)` is transparent, so over the chat the
  /// bar shows the user's wallpaper and stops reading as part of the app
  /// (issue #54). Blending onto [surface] keeps it on the same material as the
  /// rest of the chrome, and still honours the panel-opacity setting.
  Color noticeSurface(Color tint, {double alpha = 0.14}) =>
      Color.alphaBlend(tint.withValues(alpha: alpha), surface);

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

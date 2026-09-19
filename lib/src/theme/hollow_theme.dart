import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'contrast.dart';
import 'hollow_colors.dart';
import 'hollow_spacing.dart';
import 'surface_ladder.dart';

/// Hollow's custom theme extension, travelling with ThemeData. Reach it
/// through [HollowTheme.of].
class HollowTheme extends ThemeExtension<HollowTheme> {
  final Color background;
  final Color surface;
  final Color elevated;
  /// Menus, popovers, dialogs, toasts, tooltips: what floats above the app.
  final Color overlay;
  /// The hover level, one step past [overlay], for rows inside a floating
  /// surface. Controls on the canvas hover to [elevated].
  final Color hover;
  /// The flat dim behind a dialog or sheet.
  final Color scrim;
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
  /// The label on a solid error fill (the danger button).
  final Color textOnError;
  final Color border;
  final Color error;
  final Color success;
  final Color warning;
  /// Badges, chips, keycaps: the smallest stop.
  final double radiusXs;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;

  const HollowTheme({
    required this.background,
    required this.surface,
    required this.elevated,
    required this.overlay,
    required this.hover,
    required this.scrim,
    required this.accent,
    required this.accentHover,
    required this.accentMuted,
    required this.accentText,
    required this.focusRing,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.textOnAccent,
    required this.textOnError,
    required this.border,
    required this.error,
    required this.success,
    required this.warning,
    required this.radiusXs,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusXl,
  });

  factory HollowTheme.dark() => HollowTheme._build(
        ladder: SurfaceLadders.dark,
        accent: HollowColors.accent,
        accentHover: HollowColors.accentHover,
        accentMuted: HollowColors.accentMuted,
        textPrimary: HollowColors.textPrimary,
        textSecondary: HollowColors.textSecondary,
        textTertiary: HollowColors.textTertiary,
        textOnAccent: HollowColors.textOnAccent,
        border: HollowColors.border,
        error: HollowColors.error,
        success: HollowColors.success,
        warning: HollowColors.warning,
      );

  factory HollowTheme.light() => HollowTheme._build(
        ladder: SurfaceLadders.light,
        // The raw accent is ~2.3:1 on white, too light for text or a focus
        // ring, so both start from the darker foreground variant here.
        accent: HollowColors.accent,
        accentForeground: HollowColors.accentTextLight,
        accentHover: HollowColors.accentHover,
        accentMuted: HollowColors.accentMutedLight,
        textPrimary: HollowColors.textPrimaryLight,
        textSecondary: HollowColors.textSecondaryLight,
        textTertiary: HollowColors.textTertiaryLight,
        textOnAccent: HollowColors.textOnAccentLight,
        border: HollowColors.borderLight,
        error: HollowColors.errorLight,
        success: HollowColors.successLight,
        warning: HollowColors.warningLight,
      );

  factory HollowTheme.darkWithHue(double hue) => HollowTheme.dark().copyWithAccent(
        accentFromHue(hue),
        accentHoverFromHue(hue),
        accentMutedFromHue(hue),
      );

  factory HollowTheme.lightWithHue(double hue) =>
      HollowTheme.light().copyWithAccent(
        accentFromHue(hue),
        accentHoverFromHue(hue),
        accentMutedLightFromHue(hue),
      );

  /// Every foreground token is validated against ALL five surfaces rather than
  /// the one it usually sits on: a label on a hovered row or inside a menu is
  /// on the brightest (dark) or dimmest (light) level, and that is the case
  /// that fails first.
  factory HollowTheme._build({
    required SurfaceLadder ladder,
    required Color accent,
    Color? accentForeground,
    required Color accentHover,
    required Color accentMuted,
    required Color textPrimary,
    required Color textSecondary,
    required Color textTertiary,
    required Color textOnAccent,
    required Color border,
    required Color error,
    required Color success,
    required Color warning,
  }) {
    final surfaces = ladder.all;
    Color legible(Color c, [double ratio = 4.5]) =>
        Contrast.ensureContrastOnAll(c, surfaces, targetRatio: ratio);
    return HollowTheme(
      background: ladder.canvas,
      surface: ladder.chrome,
      elevated: ladder.raised,
      overlay: ladder.overlay,
      hover: ladder.hover,
      scrim: ladder.scrim,
      accent: accent,
      accentHover: accentHover,
      accentMuted: accentMuted,
      accentText: legible(accentForeground ?? accent),
      focusRing: legible(accentForeground ?? accent, 3.0),
      textPrimary: textPrimary,
      textSecondary: legible(textSecondary),
      textTertiary: legible(textTertiary),
      textOnAccent: textOnAccent,
      textOnError: HollowColors.textOnError,
      border: border,
      error: error,
      success: success,
      warning: warning,
      radiusXs: HollowRadius.xs,
      radiusMd: HollowRadius.md,
      radiusLg: HollowRadius.lg,
      radiusXl: HollowRadius.xl,
    );
  }

  /// A custom hue re-derives only the accent family, validated like the rest.
  HollowTheme copyWithAccent(Color accent, Color hover, Color muted) {
    final surfaces = [background, surface, elevated, overlay, this.hover];
    return copyWith(
      accent: accent,
      accentHover: hover,
      accentMuted: muted,
      accentText:
          Contrast.ensureContrastOnAll(accent, surfaces, targetRatio: 4.5),
      focusRing:
          Contrast.ensureContrastOnAll(accent, surfaces, targetRatio: 3.0),
    );
  }

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

  /// Chrome at full opacity: the title bar and the dock over a wallpaper.
  Color get opaqueSurface => surface.withValues(alpha: 1.0);

  /// Background for a notice strip tinted by [tint].
  ///
  /// A bare `tint.withValues(alpha: …)` is transparent, so over the chat the
  /// bar shows the user's wallpaper and stops reading as part of the app
  /// (issue #54). Blending onto [elevated] keeps it a raised strip whether it
  /// sits on the canvas or the chrome, and still honours panel opacity.
  Color noticeSurface(Color tint, {double alpha = 0.14}) =>
      Color.alphaBlend(tint.withValues(alpha: alpha), elevated);

  static HollowTheme of(BuildContext context) =>
      Theme.of(context).extension<HollowTheme>()!;

  @override
  HollowTheme copyWith({
    Color? background,
    Color? surface,
    Color? elevated,
    Color? overlay,
    Color? hover,
    Color? scrim,
    Color? accent,
    Color? accentHover,
    Color? accentMuted,
    Color? accentText,
    Color? focusRing,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textOnAccent,
    Color? textOnError,
    Color? border,
    Color? error,
    Color? success,
    Color? warning,
    double? radiusXs,
    double? radiusMd,
    double? radiusLg,
    double? radiusXl,
  }) {
    return HollowTheme(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      elevated: elevated ?? this.elevated,
      overlay: overlay ?? this.overlay,
      hover: hover ?? this.hover,
      scrim: scrim ?? this.scrim,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      accentMuted: accentMuted ?? this.accentMuted,
      accentText: accentText ?? this.accentText,
      focusRing: focusRing ?? this.focusRing,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textOnAccent: textOnAccent ?? this.textOnAccent,
      textOnError: textOnError ?? this.textOnError,
      border: border ?? this.border,
      error: error ?? this.error,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      radiusXs: radiusXs ?? this.radiusXs,
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
      overlay: Color.lerp(overlay, other.overlay, t)!,
      hover: Color.lerp(hover, other.hover, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentHover: Color.lerp(accentHover, other.accentHover, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      accentText: Color.lerp(accentText, other.accentText, t)!,
      focusRing: Color.lerp(focusRing, other.focusRing, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      textOnAccent: Color.lerp(textOnAccent, other.textOnAccent, t)!,
      textOnError: Color.lerp(textOnError, other.textOnError, t)!,
      border: Color.lerp(border, other.border, t)!,
      error: Color.lerp(error, other.error, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      radiusXs: radiusXs + (other.radiusXs - radiusXs) * t,
      radiusMd: radiusMd + (other.radiusMd - radiusMd) * t,
      radiusLg: radiusLg + (other.radiusLg - radiusLg) * t,
      radiusXl: radiusXl + (other.radiusXl - radiusXl) * t,
    );
  }
}

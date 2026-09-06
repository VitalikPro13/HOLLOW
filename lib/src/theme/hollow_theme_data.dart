import 'package:flutter/material.dart';
import 'hollow_colors.dart';
import 'hollow_spacing.dart';
import 'hollow_theme.dart';
import 'hollow_typography.dart';

/// Factory for creating Flutter ThemeData with Hollow's design system.
abstract final class HollowThemeData {
  static ThemeData dark({double? accentHue}) {
    final hollow = accentHue != null
        ? HollowTheme.darkWithHue(accentHue)
        : HollowTheme.dark();

    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: hollow.background,
      canvasColor: hollow.surface,

      colorScheme: ColorScheme.dark(
        primary: hollow.accent,
        onPrimary: hollow.textOnAccent,
        secondary: hollow.accent,
        onSecondary: hollow.textOnAccent,
        surface: hollow.surface,
        onSurface: hollow.textPrimary,
        error: hollow.error,
        onError: HollowColors.textPrimary,
      ),

      textTheme: TextTheme(
        displayLarge: HollowTypography.display,
        headlineMedium: HollowTypography.heading,
        titleMedium: HollowTypography.subheading,
        bodyLarge: HollowTypography.body,
        bodyMedium: HollowTypography.body,
        bodySmall: HollowTypography.bodySmall,
        labelLarge: HollowTypography.label,
        labelSmall: HollowTypography.caption,
      ),

      dividerTheme: DividerThemeData(
        color: hollow.border,
        thickness: 1,
        space: 1,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: hollow.elevated,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
          borderSide: BorderSide(color: hollow.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
          borderSide: BorderSide(color: hollow.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
          borderSide: BorderSide(color: hollow.accent, width: 1.5),
        ),
        hintStyle: HollowTypography.body.copyWith(
          color: hollow.textSecondary,
        ),
        labelStyle: HollowTypography.body.copyWith(
          color: hollow.textSecondary,
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(hollow.accent),
          foregroundColor: WidgetStatePropertyAll(hollow.textOnAccent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HollowRadius.md),
            ),
          ),
          textStyle: WidgetStatePropertyAll(HollowTypography.label),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(hollow.accent),
          side: WidgetStatePropertyAll(
            BorderSide(color: hollow.accent.withValues(alpha: 0.5)),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HollowRadius.md),
            ),
          ),
          textStyle: WidgetStatePropertyAll(HollowTypography.label),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(hollow.accent),
          textStyle: WidgetStatePropertyAll(HollowTypography.label),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(hollow.textSecondary),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: hollow.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HollowRadius.lg),
        ),
        titleTextStyle: HollowTypography.heading,
        contentTextStyle: HollowTypography.body,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: hollow.elevated,
        contentTextStyle: HollowTypography.body,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(HollowRadius.sm),
          border: Border.all(color: hollow.border),
        ),
        textStyle: HollowTypography.bodySmall.copyWith(
          color: hollow.textPrimary,
        ),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          hollow.textSecondary.withValues(alpha: 0.3),
        ),
        radius: const Radius.circular(HollowRadius.sm),
        thickness: const WidgetStatePropertyAll(6),
      ),

      extensions: [hollow],
    );
  }

  static ThemeData light({double? accentHue}) {
    final hollow = accentHue != null
        ? HollowTheme.lightWithHue(accentHue)
        : HollowTheme.light();

    return ThemeData(
      brightness: Brightness.light,
      scaffoldBackgroundColor: hollow.background,
      canvasColor: hollow.surface,

      colorScheme: ColorScheme.light(
        primary: hollow.accent,
        onPrimary: hollow.textOnAccent,
        secondary: hollow.accent,
        onSecondary: hollow.textOnAccent,
        surface: hollow.surface,
        onSurface: hollow.textPrimary,
        error: hollow.error,
        onError: HollowColors.textPrimaryLight,
      ),

      textTheme: TextTheme(
        displayLarge:
            HollowTypography.display.copyWith(color: hollow.textPrimary),
        headlineMedium:
            HollowTypography.heading.copyWith(color: hollow.textPrimary),
        titleMedium:
            HollowTypography.subheading.copyWith(color: hollow.textPrimary),
        bodyLarge: HollowTypography.body.copyWith(color: hollow.textPrimary),
        bodyMedium: HollowTypography.body.copyWith(color: hollow.textPrimary),
        bodySmall:
            HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
        labelLarge: HollowTypography.label.copyWith(color: hollow.textPrimary),
        labelSmall:
            HollowTypography.caption.copyWith(color: hollow.textSecondary),
      ),

      dividerTheme: DividerThemeData(
        color: hollow.border,
        thickness: 1,
        space: 1,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: hollow.elevated,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
          borderSide: BorderSide(color: hollow.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
          borderSide: BorderSide(color: hollow.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
          borderSide: BorderSide(color: hollow.accent, width: 1.5),
        ),
        hintStyle: HollowTypography.body.copyWith(
          color: hollow.textSecondary,
        ),
        labelStyle: HollowTypography.body.copyWith(
          color: hollow.textSecondary,
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStatePropertyAll(hollow.accent),
          foregroundColor: WidgetStatePropertyAll(hollow.textOnAccent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HollowRadius.md),
            ),
          ),
          textStyle: WidgetStatePropertyAll(HollowTypography.label),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(hollow.accent),
          side: WidgetStatePropertyAll(
            BorderSide(color: hollow.accent.withValues(alpha: 0.5)),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(HollowRadius.md),
            ),
          ),
          textStyle: WidgetStatePropertyAll(HollowTypography.label),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(hollow.accent),
          textStyle: WidgetStatePropertyAll(HollowTypography.label),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(hollow.textSecondary),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: hollow.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HollowRadius.lg),
        ),
        titleTextStyle:
            HollowTypography.heading.copyWith(color: hollow.textPrimary),
        contentTextStyle:
            HollowTypography.body.copyWith(color: hollow.textPrimary),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: hollow.elevated,
        contentTextStyle:
            HollowTypography.body.copyWith(color: hollow.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HollowRadius.md),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(HollowRadius.sm),
          border: Border.all(color: hollow.border),
        ),
        textStyle: HollowTypography.bodySmall.copyWith(
          color: hollow.textPrimary,
        ),
      ),

      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          hollow.textSecondary.withValues(alpha: 0.3),
        ),
        radius: const Radius.circular(HollowRadius.sm),
        thickness: const WidgetStatePropertyAll(6),
      ),

      extensions: [hollow],
    );
  }
}

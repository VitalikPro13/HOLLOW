import 'dart:ui';

/// Hollow color palette, deep dark with a teal accent.
///
/// Teal reads as calm and shelter, and is distinct from Discord's purple,
/// Signal's blue and WhatsApp's green.
abstract final class HollowColors {
  static const background = Color(0xFF0D0F14);
  static const surface = Color(0xFF14161C);
  static const elevated = Color(0xFF1A1D25);

  static const accent = Color(0xFF00BFA6);
  static const accentHover = Color(0xFF00D9BB);
  static const accentMuted = Color(0x3300BFA6);

  static const textPrimary = Color(0xFFF1F3F5);
  static const textSecondary = Color(0xFF8B919A);
  // The faded-metadata token (timestamps, "(edited)", counters): clears 4.5:1
  // on every dark surface, unlike the 0.4 alpha on textSecondary it replaces
  // (~2:1). It still reads as quieter because brighter text sits next to it.
  static const textTertiary = Color(0xFF808690);
  static const textOnAccent = Color(0xFF0D0F14);

  static const border = Color(0x14FFFFFF); // ~8% white

  static const error = Color(0xFFEF4444);
  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFFBBF24);

  static const backgroundLight = Color(0xFFFFFFFF);
  static const surfaceLight = Color(0xFFF5F6F8);
  static const elevatedLight = Color(0xFFE9EBED);

  static const accentMutedLight = Color(0x1A00BFA6); // ~10% teal on white

  // Foreground use on light surfaces (text, icons, links): the shared teal is
  // 2.33:1 on white and fails. Fills keep the raw accent.
  static const accentTextLight = Color(0xFF00796B); // 5.32:1 on white

  static const textPrimaryLight = Color(0xFF1A1C1E);
  static const textSecondaryLight = Color(0xFF5C6370);
  // Reuses secondary's luminance; the quieter read is relative to nearby
  // primary text.
  static const textTertiaryLight = Color(0xFF5C6370);
  static const textOnAccentLight = Color(0xFF0D0F14); // dark text on teal

  // Light-theme variants: the shared dark ones fail on white.
  static const errorLight = Color(0xFFB91C1C);   // 6.47:1 on white
  static const successLight = Color(0xFF047857); // 5.48:1 on white
  static const warningLight = Color(0xFF92600A); // 5.38:1 on white

  static const borderLight = Color(0x14000000); // ~8% black
}

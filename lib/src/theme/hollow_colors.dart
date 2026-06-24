import 'dart:ui';

/// Hollow color palette — Deep Dark + Teal Accent.
///
/// Teal evokes calm/shelter (aligns with "Hollow" name).
/// Distinct from Discord (purple), Signal (blue), WhatsApp (green).
abstract final class HollowColors {
  // ── Backgrounds ──
  static const background = Color(0xFF0D0F14);
  static const surface = Color(0xFF14161C);
  static const elevated = Color(0xFF1A1D25);

  // ── Accent ──
  static const accent = Color(0xFF00BFA6);
  static const accentHover = Color(0xFF00D9BB);
  static const accentMuted = Color(0x3300BFA6);

  // ── Text ──
  static const textPrimary = Color(0xFFF1F3F5);
  static const textSecondary = Color(0xFF8B919A);
  // Tertiary: the faded-metadata token (timestamps, "(edited)", counters).
  // Clears 4.5:1 on all dark surfaces (≥4.60) — replaces ad-hoc alpha 0.4–0.5
  // applied to textSecondary (which fell to ~2:1). Visually still reads as
  // "quieter than secondary" because it sits next to brighter text.
  static const textTertiary = Color(0xFF808690);
  static const textOnAccent = Color(0xFF0D0F14);

  // ── Borders ──
  static const border = Color(0x14FFFFFF); // ~8% white

  // ── Semantic ──
  static const error = Color(0xFFEF4444);
  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFFBBF24);

  // ══════════════════════════════════════════
  // ── Light Mode ──
  // ══════════════════════════════════════════

  // ── Backgrounds ──
  static const backgroundLight = Color(0xFFFFFFFF);
  static const surfaceLight = Color(0xFFF5F6F8);
  static const elevatedLight = Color(0xFFE9EBED);

  // ── Accent (muted variant only — accent/accentHover shared) ──
  static const accentMutedLight = Color(0x1A00BFA6); // ~10% teal on white

  // Darkened accent for FOREGROUND use on light surfaces (text/icons/links).
  // The shared teal accent (00BFA6) is only 2.33:1 on white — fails. This
  // variant clears 4.5:1. Fills still use the raw accent (paired with dark
  // textOnAccent, which is fine).
  static const accentTextLight = Color(0xFF00796B); // 5.32:1 on white

  // ── Text ──
  static const textPrimaryLight = Color(0xFF1A1C1E);
  static const textSecondaryLight = Color(0xFF5C6370);
  // Light tertiary reuses secondary's luminance (clears 4.5:1 everywhere);
  // the "quieter" read is relative to nearby primary text.
  static const textTertiaryLight = Color(0xFF5C6370);
  static const textOnAccentLight = Color(0xFF0D0F14); // dark text on teal

  // ── Semantic (light-theme variants — the shared dark ones fail on white) ──
  static const errorLight = Color(0xFFB91C1C);   // 6.47:1 on white
  static const successLight = Color(0xFF047857); // 5.48:1 on white
  static const warningLight = Color(0xFF92600A); // 5.38:1 on white

  // ── Borders ──
  static const borderLight = Color(0x14000000); // ~8% black
}

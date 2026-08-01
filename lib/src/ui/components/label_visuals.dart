import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Canonical preset palette for label colors (desktop and mobile share it —
/// they used to carry two divergent 9-color lists).
const kLabelPresetColors = <Color>[
  Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFEAB308),
  Color(0xFF22C55E), Color(0xFF06B6D4), Color(0xFF3B82F6),
  Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF78909C),
];

/// Canonical label color parser (accepts #RRGGBB and #AARRGGBB).
Color parseLabelColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
  if (cleaned.length == 8) return Color(int.parse(cleaned, radix: 16));
  return const Color(0xFF78909C);
}

/// Short peer-id suffix ("…T7iS4F") for disambiguating members who share a
/// display name (and possibly an avatar) in member pickers. Ellipsis + the
/// last 6 characters; ids too short to truncate pass through unchanged.
String shortPeerIdSuffix(String peerId) =>
    peerId.length > 10 ? '…${peerId.substring(peerId.length - 6)}' : peerId;

/// Cosmetic-vs-Access selector chip for the label create/edit dialog
/// (selection state is a chip, never a filled button). Shared by the
/// desktop Labels tab and the mobile Labels route.
class LabelTypeChip extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  const LabelTypeChip({
    super.key,
    required this.icon,
    required this.text,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowFocusRing(
      enabled: true,
      onActivate: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? hollow.accent.withValues(alpha: 0.15)
                : hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: selected ? hollow.accent : hollow.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13,
                  color: selected ? hollow.accentText : hollow.textSecondary),
              const SizedBox(width: 6),
              Text(
                text,
                style: HollowTypography.bodySmall.copyWith(
                  color: selected ? hollow.accentText : hollow.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A selectable label chip (the self-assign picker visual). Access labels
/// carry a shield glyph; `locked` renders the dimmed non-self-service look —
/// still focusable, and activation fires [onTap] so the caller can ANNOUNCE
/// why it is locked (tooltip/toast) instead of silently no-oping.
class LabelChip extends StatelessWidget {
  final crdt_api.LabelFfi label;
  final bool selected;
  final bool locked;
  final VoidCallback? onTap;
  final String? semanticLabel;

  const LabelChip({
    super.key,
    required this.label,
    required this.selected,
    this.locked = false,
    this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final c = parseLabelColor(label.color);
    final leadingIcon = locked
        ? LucideIcons.lock
        : (selected ? LucideIcons.check : LucideIcons.circle);

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? c.withValues(alpha: 0.25) : hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: selected ? c : hollow.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(leadingIcon, size: 12, color: c),
          const SizedBox(width: 6),
          if (label.access) ...[
            Icon(LucideIcons.shieldCheck, size: 12, color: c),
            const SizedBox(width: 4),
          ],
          // Label names are free-form user content — ellipsize so a long
          // name can't overflow the chip Row at high text scale.
          Flexible(
            child: Text(
              label.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.body.copyWith(
                color: selected ? c : hollow.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      label: semanticLabel ??
          (locked
              ? 'Access label ${label.name}, assigned by staff'
              : 'Label ${label.name}'),
      child: HollowFocusRing(
        enabled: true,
        onActivate: onTap ?? () {},
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: GestureDetector(
          onTap: onTap,
          // Dim via AnimatedOpacity (GPU-composited), never the Opacity widget.
          child: locked
              ? AnimatedOpacity(
                  opacity: 0.55,
                  duration: const Duration(milliseconds: 120),
                  child: chip,
                )
              : chip,
        ),
      ),
    );
  }
}

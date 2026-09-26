import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Canonical preset palette for label colours, shared by desktop and mobile.
const kLabelPresetColors = <Color>[
  Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFEAB308), // design-ignore: user-chosen label colours, content
  Color(0xFF22C55E), Color(0xFF06B6D4), Color(0xFF3B82F6), // design-ignore: user-chosen label colours, content
  Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFF78909C), // design-ignore: user-chosen label colours, content
];

/// Canonical label color parser (accepts #RRGGBB and #AARRGGBB).
Color parseLabelColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
  if (cleaned.length == 8) return Color(int.parse(cleaned, radix: 16));
  return kLabelPresetColors.last;
}

/// Short peer-id suffix ("…T7iS4F") that tells apart members sharing a display
/// name. An id too short to truncate passes through unchanged.
String shortPeerIdSuffix(String peerId) =>
    peerId.length > 10 ? '…${peerId.substring(peerId.length - 6)}' : peerId;

/// Cosmetic-vs-Access selector for the label create and edit dialog, and the
/// role picker: a [HollowChip] with its icon.
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
    return Semantics(
      selected: selected,
      child: HollowChip(
        label: text,
        icon: icon,
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}

/// A selectable label: a [HollowChip] led by the label's colour. `locked`
/// dims it and swaps the swatch for a lock, but keeps it focusable and still
/// fires [onTap], so the caller can ANNOUNCE why rather than silently no-op.
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
    final chip = Semantics(
      selected: selected,
      child: HollowChip(
        label: label.name,
        selected: selected,
        onTap: onTap,
        leading: LabelSwatch(label: label, locked: locked),
        semanticLabel: semanticLabel ??
            (locked
                ? 'Access label ${label.name}, assigned by staff'
                : 'Label ${label.name}'),
      ),
    );
    if (!locked) return chip;
    // Dim via AnimatedOpacity (GPU-composited), never the Opacity widget.
    return AnimatedOpacity(
      opacity: 0.55,
      duration: HollowDurations.fast,
      child: chip,
    );
  }
}

/// A label someone wears, shown as a fact: a [HollowBadge] led by the
/// label's colour. Never clickable; a label that can be toggled is a
/// [LabelChip].
class LabelBadge extends StatelessWidget {
  final crdt_api.LabelFfi label;

  const LabelBadge({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return HollowBadge(
      label.name,
      leading: LabelSwatch(label: label),
    );
  }
}

/// A label's colour as a dot, plus a shield for an access label; a lock in
/// place of the dot when the label is staff-assigned. [size] is the glyph box
/// on the icon ramp.
class LabelSwatch extends StatelessWidget {
  final crdt_api.LabelFfi label;
  final bool locked;
  final double size;

  const LabelSwatch({
    super.key,
    required this.label,
    this.locked = false,
    this.size = 14,
  });

  @override
  Widget build(BuildContext context) {
    final color = parseLabelColor(label.color);
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (locked)
            Icon(LucideIcons.lock, size: size, color: color)
          else
            SizedBox.square(
              dimension: size,
              child: Center(
                child: Container(
                  width: size * _dotRatio,
                  height: size * _dotRatio,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              ),
            ),
          if (label.access) ...[
            const SizedBox(width: HollowSpacing.xxs),
            Icon(LucideIcons.shieldCheck, size: size, color: color),
          ],
        ],
      ),
    );
  }
}

const double _dotRatio = 0.6;

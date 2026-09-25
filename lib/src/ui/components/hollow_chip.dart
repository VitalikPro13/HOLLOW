import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';

/// An interactive label: a filter, a sub-tab, a selection, something removable.
///
/// **Selection is a chip state, never a filled button.** Selected is an
/// accent-muted fill with accent text; nothing about the type changes, because
/// a weight change on select would reflow the row under the pointer.
///
/// If it does not respond to a tap it is a [HollowBadge].
class HollowChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  /// Only when it carries meaning the word does not. Rendered at 14.
  final IconData? icon;

  /// A glyph that is not an [IconData], such as a platform logo. Sized by the
  /// caller at 14; wins over [icon].
  final Widget? leading;

  /// Quieter text after the label, for the one fact that tells two choices
  /// apart ("light, instant" beside an engine name).
  final String? hint;

  /// Something waiting on the person behind this chip (requests to answer),
  /// as a [HollowCountBadge] after the label. A plain total is [hint].
  final int? count;

  /// What a tap does beyond selecting: a chevron for a chip that opens a menu,
  /// an arrow for one that leaves the app.
  final IconData? trailingIcon;

  /// Turns the chip into a removable one. The X is part of the chip, so the
  /// whole control stays one screen-reader stop.
  final VoidCallback? onRemove;

  /// Fills the width it is given, for a row of equal-width sub-tabs. The
  /// caller still wraps it in [Expanded]; this is what stops the label from
  /// shrink-wrapping inside that space.
  final bool expand;

  /// Usually null: [label] names the chip. Set it when the visible text is the
  /// wrong announcement.
  final String? semanticLabel;

  /// For a group that moves focus itself, as [HollowChipTabs] does.
  final FocusNode? focusNode;

  const HollowChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.icon,
    this.leading,
    this.hint,
    this.count,
    this.trailingIcon,
    this.onRemove,
    this.expand = false,
    this.semanticLabel,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final foreground = selected ? hollow.accentText : hollow.textSecondary;
    final radius = BorderRadius.circular(hollow.radiusXs);

    return HollowPressable(
      onTap: onTap,
      borderRadius: radius,
      // Null, not a transparent colour: HollowPressable resolves the resting
      // fill to its hover colour at zero alpha, which is what keeps the
      // unselected chip from flashing black on hover.
      backgroundColor: selected ? hollow.accentMuted : null,
      border: Border.all(
        // Softened, not the full accent: the muted fill and the accent label
        // already say "selected", and a hard teal outline on every sub-tab row
        // shouts louder than the content it labels.
        color: selected
            ? hollow.accent.withValues(alpha: _selectedEdge)
            : hollow.border,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      semanticLabel: semanticLabel,
      focusNode: focusNode,
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment:
            expand ? MainAxisAlignment.center : MainAxisAlignment.start,
        children: [
          if (leading != null || icon != null) ...[
            leading ?? Icon(icon, size: _iconSize, color: foreground),
            const SizedBox(width: HollowSpacing.xs),
          ],
          // Flexible with an ellipsis, always: a row of equal-width sub-tabs
          // divides the width between them, and at a large text scale the
          // longest label would otherwise overflow its own chip.
          Flexible(
            child: Text(
              label,
              style: HollowTypography.label.copyWith(color: foreground),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            Text(
              hint!,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary),
              maxLines: 1,
            ),
          ],
          if (count != null && count! > 0) ...[
            const SizedBox(width: HollowSpacing.xs),
            Semantics(
              label: '$count waiting',
              child: ExcludeSemantics(child: HollowCountBadge(count: count!)),
            ),
          ],
          if (trailingIcon != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            Icon(trailingIcon, size: _iconSize, color: hollow.textTertiary),
          ],
          if (onRemove != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            // The chip merges its descendants into one screen-reader stop, so
            // the X needs its own name here or removal is an unlabelled target
            // for Voice Control and announces nothing.
            Semantics(
              button: true,
              label: 'Remove $label',
              child: HollowTooltip(
                message: 'Remove',
                child: GestureDetector(
                  onTap: onRemove,
                  child:
                      Icon(LucideIcons.x, size: _iconSize, color: foreground),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

const double _iconSize = 14;
const double _selectedEdge = 0.5;

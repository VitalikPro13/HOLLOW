import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// One row of a dense list: leading, title, subtitle, trailing.
///
/// Anything repeated more than three times is a list of these, not a grid of
/// cards, unless the item IS the art.
///
/// The hover fill belongs to the WHOLE row and the rows sit flush, so a pointer
/// travelling down a list never crosses a dead gap where the highlight drops
/// out. Padding lives inside the row for the same reason: a margin would put
/// unreachable space between two hover targets.
class HollowListRow extends StatelessWidget {
  /// An avatar, a status dot, an icon that carries meaning. Never an icon in a
  /// tinted box.
  final Widget? leading;

  final String title;
  final String? subtitle;

  /// A badge, a count, a ghost action.
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Persistent selection, as in a sidebar. Distinct from hover and press.
  final bool selected;

  /// Usually null: [title] names the row.
  final String? semanticLabel;

  const HollowListRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      // A row is not a button: it stays actionable for assistive tech without
      // claiming the button role.
      semanticButton: false,
      semanticLabel: semanticLabel,
      // Hover colour only. A row must not scale or dim under the pointer: at
      // list density that reads as the whole list twitching.
      subtle: true,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      backgroundColor: selected ? hollow.accentMuted : null,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: HollowSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: HollowTypography.label.copyWith(
                    color: selected ? hollow.accentText : hollow.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: HollowSpacing.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}

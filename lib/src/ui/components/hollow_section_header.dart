import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

/// The title above a group of things, with an optional count and one trailing
/// action.
///
/// **There is no leading-icon parameter.** An icon beside a heading is
/// decoration, it is the single most common generated-UI tell in the app, and
/// leaving the parameter out is what stops it coming back.
///
/// Sentence case, never tracked capitals: the hierarchy is carried by weight
/// and colour.
class HollowSectionHeader extends StatelessWidget {
  final String title;

  /// Shown after the title in the console voice, for "12" or "3 of 8".
  final String? count;

  /// One action, at the trailing edge. A ghost button unless this section owns
  /// the screen's single primary.
  final Widget? action;

  /// One quiet line under the title ("or drop a .hollowpack here"). The
  /// action centres on the title and this line together, so a tall button
  /// never pushes the line away from its title.
  final String? subtitle;

  /// A sub-group inside a section, rather than the section itself.
  final bool dense;

  const HollowSectionHeader(
    this.title, {
    super.key,
    this.count,
    this.action,
    this.subtitle,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final titleRow = Row(
      children: [
        Flexible(
          child: Text(
            title,
            style: (dense ? HollowTypography.label : HollowTypography.subheading)
                .copyWith(color: hollow.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (count != null) ...[
          const SizedBox(width: HollowSpacing.sm),
          Text(
            count!,
            style: HollowTypography.monoSmall.copyWith(
              color: hollow.textTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Row(
        children: [
          // The title and its count are one group that takes the whole width
          // less the action. A Spacer here instead would share the free space
          // with the title's own Flexible and strand the action mid-row.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                titleRow,
                if (subtitle != null) ...[
                  const SizedBox(height: HollowSpacing.xxs),
                  Text(
                    subtitle!,
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          if (action != null) ...[
            const SizedBox(width: HollowSpacing.sm),
            action!,
          ],
        ],
      ),
    );
  }
}

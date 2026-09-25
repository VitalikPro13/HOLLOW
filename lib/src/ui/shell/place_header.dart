import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

/// The strip's height: fixed, so switching tabs whose actions differ never
/// moves the content below.
const double kPlaceHeaderHeight = 52;

/// The title strip of a place (Archive, Share, Conferences): the title, its
/// tab chips beside it, and the actions 8 apart at the trailing edge.
class PlaceHeader extends StatelessWidget {
  final String title;

  /// One [HollowChipTabs], the same tab row every dialog and page uses.
  final List<Widget> tabs;
  final List<Widget> actions;

  const PlaceHeader({
    super.key,
    required this.title,
    this.tabs = const [],
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      height: kPlaceHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          // The title yields to the actions, never the other way round: a long
          // meeting name ellipsizes before End meeting moves.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: HollowTypography.heading
                        .copyWith(color: hollow.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (tabs.isNotEmpty) const SizedBox(width: HollowSpacing.lg),
                for (var i = 0; i < tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: HollowSpacing.sm),
                  tabs[i],
                ],
              ],
            ),
          ),
          for (var i = 0; i < actions.length; i++) ...[
            const SizedBox(width: HollowSpacing.sm),
            actions[i],
          ],
        ],
      ),
    );
  }
}

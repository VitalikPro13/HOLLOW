import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

/// The unread counter on a conversation, channel, server or friend.
///
/// Unread is the accent; a mention is the error colour and carries an `@`, so
/// red keeps meaning "someone needs you" and never just "there is more".
/// Distinct from [HollowBadge], which states a fact in a wash: this one is a
/// solid notification mark.
///
/// [ring] is the surface it sits on, for a counter that overlaps the corner of
/// an avatar or server icon and needs a cut-out to stay legible.
class HollowCountBadge extends StatelessWidget {
  final int count;
  final bool mention;
  final Color? ring;

  const HollowCountBadge({
    super.key,
    required this.count,
    this.mention = false,
    this.ring,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final shown = count > 99 ? '99+' : '$count';
    final ringWidth = ring == null ? 0.0 : HollowSpacing.xxs;
    return Container(
      constraints: BoxConstraints(
        minWidth: _height + ringWidth * 2,
        minHeight: _height + ringWidth * 2,
      ),
      // A Container folds the border into its padding, so none is added here.
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
      decoration: BoxDecoration(
        color: mention ? hollow.errorFill : hollow.accent,
        borderRadius: BorderRadius.circular(_height),
        border: ring == null ? null : Border.all(color: ring!, width: ringWidth),
      ),
      // Factors of 1, never a bare alignment: that fills whatever height a
      // Row hands it, and the badge stretches to the height of the strip.
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          mention ? '@$shown' : shown,
          style: HollowTypography.micro.copyWith(
            color: mention ? hollow.textOnError : hollow.textOnAccent,
            fontWeight: FontWeight.w600,
            height: 1,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

const double _height = 16;

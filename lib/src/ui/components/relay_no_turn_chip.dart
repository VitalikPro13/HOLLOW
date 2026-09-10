import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';

/// Marks a relay that reported no TURN server, so a call there only works when
/// the two people can reach each other directly.
class RelayNoTurnChip extends StatelessWidget {
  const RelayNoTurnChip({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowTooltip(
      message: 'Calls need a direct route on this relay',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : HollowSpacing.sm,
          vertical: compact ? 1 : 2,
        ),
        decoration: BoxDecoration(
          color: hollow.warning.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(compact ? 4 : hollow.radiusSm),
        ),
        child: Text(
          'No TURN server',
          style: HollowTypography.caption.copyWith(
            color: hollow.warning,
            fontSize: compact ? 9 : 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

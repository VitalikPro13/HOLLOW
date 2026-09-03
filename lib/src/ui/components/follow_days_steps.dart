import 'package:flutter/material.dart';

import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

import 'hollow_pressable.dart';

/// The follow ages a Twitch follow credential can carry, in days.
///
/// The shop signs each threshold under its own key, and blind signing binds a
/// value only through the key that signs it, so a join gate can only ever ask
/// for one of these. A server setting between two steps used to round up to
/// the next one silently; the picker offers the steps and nothing else.
const List<int> kFollowDaySteps = [0, 1, 3, 7, 14, 30, 60, 90, 180, 365];

/// The step a stored setting actually enforces: the smallest step at or above
/// it. A legacy value of 10 was enforced as 14, and the picker shows 14.
int effectiveFollowStep(int value) {
  for (final step in kFollowDaySteps) {
    if (step >= value) return step;
  }
  return kFollowDaySteps.last;
}

/// One chip per step; the selected one is the threshold the gate enforces.
class FollowDaysSteps extends StatelessWidget {
  const FollowDaysSteps({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final selected = effectiveFollowStep(value);
    return Wrap(
      spacing: HollowSpacing.xs,
      runSpacing: HollowSpacing.xs,
      children: [
        for (final step in kFollowDaySteps)
          _StepChip(
            label: step == 0 ? 'any' : '$step',
            semanticLabel: step == 0
                ? 'Minimum follow days: any follow'
                : 'Minimum follow days: $step',
            selected: step == selected,
            onTap: () => onChanged(step),
            hollow: hollow,
          ),
      ],
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.label,
    required this.semanticLabel,
    required this.selected,
    required this.onTap,
    required this.hollow,
  });

  final String label;
  final String semanticLabel;
  final bool selected;
  final VoidCallback onTap;
  final HollowTheme hollow;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(hollow.radiusSm);
    return HollowPressable(
      onTap: onTap,
      borderRadius: radius,
      semanticLabel: semanticLabel,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: selected ? hollow.accent.withValues(alpha: 0.12) : null,
          borderRadius: radius,
          border: Border.all(
            color: selected ? hollow.accent : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.caption.copyWith(
            color: selected ? hollow.accentText : hollow.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Single stat row: icon, label, right-aligned value and an animated progress
/// bar. Shared so desktop Home and the mobile relay card render the same one.
class StatBar extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String label;
  final String value;
  final double progress;

  const StatBar({
    super.key,
    required this.hollow,
    required this.icon,
    required this.label,
    required this.value,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    // Color shifts from accent → warning → error as usage increases.
    final Color barColor;
    if (progress < 0.6) {
      barColor = hollow.accent;
    } else if (progress < 0.85) {
      barColor = hollow.warning;
    } else {
      barColor = hollow.error;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          return Row(
            children: [
              Icon(icon, size: 12, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.xs),
              // The label yields and the value keeps the trailing edge: the
              // number is what you came to read. At Larger Text on a phone the
              // value is capped and fades rather than pushing past the card.
              Expanded(
                child: Text(
                  label,
                  style: HollowTypography.micro
                      .copyWith(color: hollow.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: constraints.maxWidth * 0.6),
                child: Text(
                  value,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: HollowTypography.micro.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          );
        }),
        const SizedBox(height: 4),
        _ThresholdBar(hollow: hollow, progress: progress, color: barColor),
      ],
    );
  }
}

/// The shared 4px track+fill bar with animated width.
class _ThresholdBar extends StatelessWidget {
  final HollowTheme hollow;
  final double progress;
  final Color color;

  const _ThresholdBar({
    required this.hollow,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: 4,
        width: double.infinity,
        child: Stack(
          children: [
            Container(color: hollow.border),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
              duration: HollowDurations.slow,
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: value,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

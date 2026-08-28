import 'package:flutter/material.dart';

import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Single stat row with icon + label + right-aligned value + animated
/// progress bar. Promoted from the desktop Home `_RelayStatsCard` so the
/// mobile Settings relay card renders the identical bar.
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
        Row(
          children: [
            Icon(icon, size: 12, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            // The label yields, the value does not: "480 / 7940 MB" is the
            // number you came to read, while "Daily relay data" can ellipse.
            // Both were bare Texts either side of a Spacer, which overflowed
            // this card by 8px at EVERY window size — the Spacer claimed the
            // free space, so a long label + long value had nowhere to go.
            // Expanded, not Flexible: beside a Spacer they would each take
            // half the room and the label would ellipse far too early.
            Expanded(
              child: Text(
                label,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              value,
              style: HollowTypography.caption.copyWith(
                color: hollow.textPrimary,
                fontSize: 10,
              ),
            ),
          ],
        ),
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

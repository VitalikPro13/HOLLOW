import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// The determinate progress bar: a transfer, an upload, a recovery.
///
/// A state, not a decoration, so it never animates on its own: the fill moves
/// only when [value] does. Indeterminate waits take `HollowSpinner`.
class HollowProgressBar extends StatelessWidget {
  /// 0 to 1; values outside are clamped.
  final double value;

  /// A semantic tone (success, warning) in place of the accent.
  final Color? color;

  /// What the bar measures, for screen readers ("Download progress").
  final String? semanticLabel;

  const HollowProgressBar({
    super.key,
    required this.value,
    this.color,
    this.semanticLabel,
  });

  static const double height = 4;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    final radius = BorderRadius.circular(hollow.radiusXs);
    return Semantics(
      label: semanticLabel,
      value: '${(v * 100).round()}%',
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(color: hollow.border, borderRadius: radius),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: v,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color ?? hollow.accent,
                  borderRadius: radius,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

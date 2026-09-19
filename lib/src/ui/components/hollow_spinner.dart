import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// Where a spinner sits decides its size, never the call site's taste.
enum HollowSpinnerSize {
  /// Inside a button, beside a label, at the end of a row.
  small,

  /// A card or a section waiting on its content.
  medium,

  /// A whole pane waiting on its content.
  large,
}

/// The one busy indicator.
///
/// Quiet by default: a spinner reports a state, it is not an action, so it
/// takes `textSecondary` rather than the accent. A button that is busy shows
/// one through `HollowButton(loading: true)`, never by swapping its child.
///
/// [value] draws a determinate ring on the same geometry, for the few places
/// a known fraction is shown in a spinner's slot; anything longer than ten
/// seconds deserves a progress bar instead.
class HollowSpinner extends StatelessWidget {
  final HollowSpinnerSize size;

  /// Defaults to `textSecondary`. Pass the foreground of the surface it sits
  /// on when that is not the canvas (a filled button, a scrim over video).
  final Color? color;

  final double? value;

  const HollowSpinner({
    super.key,
    this.size = HollowSpinnerSize.small,
    this.color,
    this.value,
  });

  const HollowSpinner.medium({super.key, this.color, this.value})
      : size = HollowSpinnerSize.medium;

  const HollowSpinner.large({super.key, this.color, this.value})
      : size = HollowSpinnerSize.large;

  static double dimensionOf(HollowSpinnerSize size) => switch (size) {
        HollowSpinnerSize.small => 14,
        HollowSpinnerSize.medium => 20,
        HollowSpinnerSize.large => 32,
      };

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dimension = dimensionOf(size);

    return Semantics(
      label: value == null ? 'Loading' : null,
      value: value == null ? null : '${(value! * 100).round()}%',
      child: SizedBox.square(
        dimension: dimension,
        child: CircularProgressIndicator(
          value: value,
          strokeWidth: size == HollowSpinnerSize.large ? 2.5 : 2,
          color: color ?? hollow.textSecondary,
          backgroundColor: value == null
              ? null
              : (color ?? hollow.textSecondary).withValues(alpha: 0.2),
        ),
      ),
    );
  }
}

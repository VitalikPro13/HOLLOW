import 'dart:async';

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
class HollowSpinner extends StatefulWidget {
  final HollowSpinnerSize size;

  /// Defaults to `textSecondary`. Pass the foreground of the surface it sits
  /// on when that is not the canvas (a filled button, a scrim over video).
  final Color? color;

  final double? value;

  /// Holds the slot empty for [revealAfter] first, for a load that is usually
  /// fast: nothing shows for under a second, so a quick one never flashes.
  /// Never on a button, where the press needs its answer at once.
  final bool delayed;

  static const revealAfter = Duration(seconds: 1);

  const HollowSpinner({
    super.key,
    this.size = HollowSpinnerSize.small,
    this.color,
    this.value,
    this.delayed = false,
  });

  const HollowSpinner.medium(
      {super.key, this.color, this.value, this.delayed = false})
      : size = HollowSpinnerSize.medium;

  const HollowSpinner.large(
      {super.key, this.color, this.value, this.delayed = false})
      : size = HollowSpinnerSize.large;

  static double dimensionOf(HollowSpinnerSize size) => switch (size) {
        HollowSpinnerSize.small => 14,
        HollowSpinnerSize.medium => 20,
        HollowSpinnerSize.large => 32,
      };

  @override
  State<HollowSpinner> createState() => _HollowSpinnerState();
}

class _HollowSpinnerState extends State<HollowSpinner> {
  Timer? _reveal;
  late bool _shown = !widget.delayed;

  @override
  void initState() {
    super.initState();
    if (!_shown) {
      _reveal = Timer(HollowSpinner.revealAfter, () {
        if (mounted) setState(() => _shown = true);
      });
    }
  }

  @override
  void dispose() {
    _reveal?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final size = widget.size;
    final value = widget.value;
    final color = widget.color;
    final dimension = HollowSpinner.dimensionOf(size);
    if (!_shown) return SizedBox.square(dimension: dimension);

    return Semantics(
      label: value == null ? 'Loading' : null,
      value: value == null ? null : '${(value * 100).round()}%',
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

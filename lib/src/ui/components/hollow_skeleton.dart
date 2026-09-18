import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// A placeholder that holds the shape of the thing still loading.
///
/// Only for a wait of roughly two to ten seconds. Under a second shows
/// nothing, over ten wants a progress bar, and a transfer wants real progress
/// rather than a guess. The point is that the layout does not jump when the
/// content lands, so a skeleton is built at the FINAL geometry.
///
/// It does not shimmer. A shimmer is an animation that runs for as long as the
/// wait does, and a running Ticker asks for a frame every vsync, which is a
/// real cost paid for decoration on a screen nobody is reading yet.
class HollowSkeleton extends StatelessWidget {
  final double? width;
  final double height;

  /// Defaults to the small-control stop. Pass [HollowSkeleton.circle] for an
  /// avatar rather than computing a radius here.
  final double? radius;

  const HollowSkeleton({
    super.key,
    required this.height,
    this.width,
    this.radius,
  });

  /// An avatar or a status glyph.
  const HollowSkeleton.circle(double diameter, {super.key})
      : width = diameter,
        height = diameter,
        radius = diameter;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(radius ?? hollow.radiusXs),
      ),
    );
  }
}

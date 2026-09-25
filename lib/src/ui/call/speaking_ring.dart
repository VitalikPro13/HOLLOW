import 'package:flutter/widgets.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// The one speaking cue: a ring in the person's own colour (yours the accent),
/// no glow. It paints OUTSIDE its child, a [gap] off it, so a VAD flip never
/// re-lays anything out, the video texture least of all. The ring overflows
/// into the surrounding padding; hosts that clip leave [outset] of room.
class SpeakingRing extends StatelessWidget {
  final bool speaking;
  final Color color;

  /// The child's corner radius; the ring runs concentric to it.
  final double radius;
  final double stroke;
  final double gap;
  final Widget child;

  const SpeakingRing({
    super.key,
    required this.speaking,
    required this.color,
    required this.radius,
    required this.child,
    this.stroke = 2,
    this.gap = 2,
  });

  /// The 20 px avatar in a dense sidebar row.
  const SpeakingRing.dense({
    super.key,
    required this.speaking,
    required this.color,
    required this.radius,
    required this.child,
  })  : stroke = 1.5,
        gap = 1.5;

  /// The phone's large call avatar.
  const SpeakingRing.large({
    super.key,
    required this.speaking,
    required this.color,
    required this.radius,
    required this.child,
  })  : stroke = 3,
        gap = 3;

  double get outset => stroke + gap;

  @override
  Widget build(BuildContext context) {
    final out = outset;
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        // Kept in the tree in both states: swapping Semantics in and out
        // remounts the subtree, and a video under it blinks.
        Semantics(
          label: speaking ? 'Speaking' : null,
          container: speaking,
          child: child,
        ),
        Positioned(
          left: -out,
          top: -out,
          right: -out,
          bottom: -out,
          child: IgnorePointer(
            // Fades from the ring's own colour at zero alpha: from
            // Colors.transparent it would lerp through black.
            child: AnimatedContainer(
              duration: HollowDurations.fast,
              curve: HollowCurves.subtle,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius + out),
                border: Border.all(
                  color: speaking ? color : color.withValues(alpha: 0),
                  width: stroke,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

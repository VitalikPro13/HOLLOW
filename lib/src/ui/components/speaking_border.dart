import 'package:flutter/material.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// Speaking cue for VIDEO surfaces: an accent ring painted ON TOP of a tile
/// rather than around it. Drop it in a `Positioned.fill` over the video.
///
/// [SpeakingBorder] pads its child, which would resize the tile on every VAD
/// flip and relayout the texture 1-4x a second. This one is layout-neutral:
/// only an overlay layer repaints, fading via [AnimatedOpacity] rather than by
/// lerping a border colour from transparent.
class SpeakingRing extends StatelessWidget {
  final bool isSpeaking;
  final BorderRadius borderRadius;
  final double borderWidth;

  const SpeakingRing({
    super.key,
    required this.isSpeaking,
    required this.borderRadius,
    this.borderWidth = 2.5,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return IgnorePointer(
      // The ring is colour, so mirror it to screen readers. Kept in the tree in
      // both states, because swapping Semantics in and out remounts the
      // subtree.
      child: Semantics(
        label: isSpeaking ? 'Speaking' : null,
        container: isSpeaking,
        child: AnimatedOpacity(
          opacity: isSpeaking ? 1.0 : 0.0,
          duration: ReduceMotionController.instance.isReduced
              ? Duration.zero
              : const Duration(milliseconds: 200),
          // BORDER ONLY, no boxShadow: on a decoration with no background
          // colour a shadow paints a FILLED blurred rect, and this sits ON TOP
          // of the video. SpeakingBorder can afford a glow, painting behind.
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: hollow.accent, width: borderWidth),
            ),
          ),
        ),
      ),
    );
  }
}

/// Speaking cue for an avatar in a DENSE row: an outline that hugs the
/// avatar's edge and costs nothing in layout.
///
/// [SpeakingBorder] pads the child outward, growing it by
/// `2 * (padding + borderWidth)`, which in a sidebar row reads as a fat, offset
/// avatar. Here the outline is a sibling painted BEHIND the avatar and inset
/// NEGATIVELY, so its inner edge lands on the avatar's edge (a rim drawn inside
/// vanishes against a matching avatar) and the row's geometry never changes:
/// the ring overflows into the surrounding padding instead of taking space.
class SpeakingAvatarOutline extends StatelessWidget {
  final bool isSpeaking;

  /// The avatar's edge length. The outline hugs this box.
  final double size;

  /// Corner radius of the AVATAR. The outline is drawn concentric at
  /// `radius + borderWidth`, so it never cuts across the corner.
  final double radius;
  final double borderWidth;
  final Widget child;

  const SpeakingAvatarOutline({
    super.key,
    required this.isSpeaking,
    required this.size,
    required this.radius,
    required this.child,
    this.borderWidth = 2.0,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -borderWidth,
            top: -borderWidth,
            right: -borderWidth,
            bottom: -borderWidth,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: isSpeaking ? 1.0 : 0.0,
                duration: ReduceMotionController.instance.isReduced
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(radius + borderWidth),
                    border:
                        Border.all(color: hollow.accent, width: borderWidth),
                    boxShadow: [
                      BoxShadow(
                        color: hollow.accent.withValues(alpha: 0.35),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Kept in the tree in both states, so the avatar subtree never
          // remounts on a flip.
          Semantics(
            label: isSpeaking ? 'Speaking' : null,
            container: isSpeaking,
            child: child,
          ),
        ],
      ),
    );
  }
}

class SpeakingBorder extends StatefulWidget {
  final bool isSpeaking;
  final Widget child;
  final double borderWidth;
  final double glowBlur;
  final double glowSpread;
  final double padding;
  final BorderRadius? borderRadius;

  const SpeakingBorder({
    super.key,
    required this.isSpeaking,
    required this.child,
    this.borderWidth = 2.5,
    this.glowBlur = 12,
    this.glowSpread = 1.5,
    this.padding = 3.0,
    this.borderRadius,
  });

  @override
  State<SpeakingBorder> createState() => _SpeakingBorderState();
}

class _SpeakingBorderState extends State<SpeakingBorder>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: ReduceMotionController.instance.isReduced
          ? Duration.zero
          : const Duration(milliseconds: 300),
    );
    _anim = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    if (widget.isSpeaking) _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(SpeakingBorder old) {
    super.didUpdateWidget(old);
    // With reduce motion the duration is zero, so the border still appears as
    // an info cue, just without the fade.
    if (widget.isSpeaking && !old.isSpeaking) {
      _controller.forward();
    } else if (!widget.isSpeaking && old.isSpeaking) {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = widget.borderRadius ??
        BorderRadius.circular(hollow.radiusMd + widget.padding);
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final v = _anim.value;
        return Container(
          padding: EdgeInsets.all(widget.padding),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: hollow.accent.withValues(alpha: v * 0.9),
              width: widget.borderWidth,
            ),
            boxShadow: v > 0.01
                ? [
                    BoxShadow(
                      color: hollow.accent.withValues(alpha: v * 0.3),
                      blurRadius: widget.glowBlur * v,
                      spreadRadius: widget.glowSpread * v,
                    ),
                  ]
                : null,
          ),
          child: child,
        );
      },
      // Mirrors the accent glow to screen readers so the state is not
      // colour-only; the label merges with the child avatar's name. The widget
      // stays in the tree in BOTH states, because swapping it in and out
      // remounts the avatar subtree and makes it blink.
      child: Semantics(
        label: widget.isSpeaking ? 'Speaking' : null,
        container: widget.isSpeaking,
        child: widget.child,
      ),
    );
  }
}

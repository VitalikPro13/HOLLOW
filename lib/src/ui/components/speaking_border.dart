import 'package:flutter/material.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// Speaking cue for VIDEO surfaces: an accent ring painted ON TOP of a tile
/// rather than around it. Drop it in a `Positioned.fill` over the video.
///
/// [SpeakingBorder] wraps its child and pads it, which is right for an avatar
/// but wrong for video — it would resize the tile on every VAD flip and force
/// the texture to relayout 1-4x per second. This one is layout-neutral: only
/// a cheap overlay layer repaints, and the ring fades via [AnimatedOpacity]
/// (GPU-composited) rather than by lerping a border colour from transparent.
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
      // Same non-colour-only cue as SpeakingBorder: the ring is an accent
      // glow, so mirror it to screen readers. Kept in the tree in both
      // states — swapping Semantics in/out remounts the subtree.
      child: Semantics(
        label: isSpeaking ? 'Speaking' : null,
        container: isSpeaking,
        child: AnimatedOpacity(
          opacity: isSpeaking ? 1.0 : 0.0,
          duration: ReduceMotionController.instance.isReduced
              ? Duration.zero
              : const Duration(milliseconds: 200),
          // BORDER ONLY — no boxShadow. A BoxShadow on a decoration with no
          // background colour paints a FILLED blurred rounded-rect, and this
          // sits ON TOP of the video, so the accent washed over the whole
          // tile instead of hugging its edge. SpeakingBorder can afford a
          // glow because it paints BEHIND its child; this one cannot.
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
/// [SpeakingBorder] is the right tool when the avatar has room around it —
/// it pads the child outward, so the ring sits a gap away and the whole
/// thing grows by `2 * (padding + borderWidth)`. In a sidebar row that
/// reads as a fat, uneven, offset avatar. Here the outline is a sibling
/// painted BEHIND the avatar and inset NEGATIVELY, so:
///   - its inner edge lands exactly on the avatar's edge — outline outside
///     the art (a teal rim drawn inside vanishes against a green avatar),
///     with no gap between the two;
///   - the row's geometry never changes, whether or not anyone is talking,
///     because the ring overflows into the surrounding padding instead of
///     taking space (`Clip.none` — the Stack still measures the avatar).
///
/// Behind the child, so the glow blooms outward without washing the art —
/// see the note on [SpeakingRing] about shadows painted on top.
class SpeakingAvatarOutline extends StatelessWidget {
  final bool isSpeaking;

  /// The avatar's edge length. The outline hugs this box.
  final double size;

  /// Corner radius of the AVATAR. The outline is drawn concentric, at
  /// `radius + borderWidth`, so it stays parallel to the avatar's corner
  /// instead of cutting across it.
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
          // Same non-colour-only cue as the other two, and kept in the tree
          // in both states so the avatar subtree never remounts on a flip.
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
    // With reduce-motion the duration is zero, so forward/reverse snap
    // instantly — the border still appears as an info cue, just without fade.
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
      // The accent glow is the visual "speaking" cue. Mirror it to screen
      // readers so the state isn't color-only: when speaking, annotate the
      // subtree with "Speaking" — it merges with the child avatar's existing
      // name (→ "Alice, Speaking"). When silent the label is null (no-op).
      // The Semantics widget stays in the tree in BOTH states: swapping it
      // in/out changed the child's element type on every VAD toggle, which
      // remounted the avatar subtree and made it blink (visible re-decode).
      child: Semantics(
        label: widget.isSpeaking ? 'Speaking' : null,
        container: widget.isSpeaking,
        child: widget.child,
      ),
    );
  }
}

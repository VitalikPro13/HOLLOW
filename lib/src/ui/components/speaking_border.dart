import 'package:flutter/material.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

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
      // name (→ "Alice, Speaking"). When silent, add nothing.
      child: widget.isSpeaking
          ? Semantics(label: 'Speaking', container: true, child: widget.child)
          : widget.child,
    );
  }
}

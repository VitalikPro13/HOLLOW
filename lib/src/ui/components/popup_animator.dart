import 'package:flutter/material.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Scale-and-fade entry/exit for anchored popups that live in a raw
/// [OverlayEntry] (the emoji, GIF and sticker pickers).
///
/// A dialog route gets its transition from the route; a raw overlay entry
/// appears and vanishes on one frame, which reads as a flicker.
///
/// The exit is the awkward half, because the entry is removed by the `show*()`
/// closure rather than by the widget. [PopupAnimationController] bridges that:
/// call [PopupAnimationController.dismiss] instead of removing the entry, and
/// it plays the exit before invoking the teardown. Reduce motion collapses both
/// directions to zero, so dismissal stays instant.
class PopupAnimationController {
  _PopupAnimatorState? _state;
  final ValueNotifier<bool> _exiting = ValueNotifier<bool>(false);

  /// Wraps the popup's ENTIRE overlay entry, dismiss barrier included, so it
  /// stops taking pointer events the moment the exit starts. Otherwise the
  /// full-screen barrier swallows clicks for the length of the exit, and a
  /// dismiss followed by a click on the reopening button loses the second.
  Widget wrapEntry(Widget child) {
    return ValueListenableBuilder<bool>(
      valueListenable: _exiting,
      builder: (_, exiting, inner) =>
          IgnorePointer(ignoring: exiting, child: inner),
      child: child,
    );
  }

  /// Plays the exit, then calls [onDone]. Falls straight through when no
  /// animator is attached, so a caller can always treat this as "remove the
  /// entry".
  void dismiss(VoidCallback onDone) {
    if (_exiting.value) return;
    _exiting.value = true;

    void finish() {
      onDone();
      _exiting.dispose();
    }

    final state = _state;
    if (state == null || !state.mounted) {
      finish();
      return;
    }
    state._playExit(finish);
  }
}

class PopupAnimator extends StatefulWidget {
  final Widget child;

  /// Corner the popup grows out of; point it at the control that opened it.
  final Alignment alignment;

  /// Optional handle so the owning `show*()` can play the exit before it
  /// removes the overlay entry.
  final PopupAnimationController? controller;

  const PopupAnimator({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
    this.controller,
  });

  @override
  State<PopupAnimator> createState() => _PopupAnimatorState();
}

class _PopupAnimatorState extends State<PopupAnimator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _fade;

  /// Stops a second dismiss landing mid-exit from restarting the reverse.
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    final duration = HollowDurations.animationsDisabled
        ? Duration.zero
        : const Duration(milliseconds: 140);
    _controller = AnimationController(
      vsync: this,
      duration: duration,
      reverseDuration: duration,
    );
    _scale = Tween<double>(begin: 0.94, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: HollowCurves.enter,
        reverseCurve: HollowCurves.exit,
      ),
    );
    _fade = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );
    widget.controller?._state = this;
    _controller.forward();
  }

  @override
  void didUpdateWidget(PopupAnimator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (identical(oldWidget.controller?._state, this)) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (identical(widget.controller?._state, this)) {
      widget.controller?._state = null;
    }
    _controller.dispose();
    super.dispose();
  }

  void _playExit(VoidCallback onDone) {
    if (_exiting) return;
    _exiting = true;
    _controller.reverse().whenComplete(onDone);
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      // A popup is hit-testable from its first frame, so hiding it from
      // assistive tech during the fade would make semantics disagree with what
      // a click already does.
      alwaysIncludeSemantics: true,
      child: ScaleTransition(
        scale: _scale,
        alignment: widget.alignment,
        child: widget.child,
      ),
    );
  }
}

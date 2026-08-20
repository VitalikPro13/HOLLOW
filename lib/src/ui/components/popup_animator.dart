import 'package:flutter/material.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Scale-and-fade entry/exit for anchored popups that live in a raw
/// [OverlayEntry] (the emoji, GIF and sticker pickers).
///
/// A dialog route gets its transition from the route itself. A raw overlay
/// entry gets nothing: it appears and vanishes on a single frame, which reads
/// as a flicker next to every other surface in the app. This widget supplies
/// the missing half.
///
/// The exit is the awkward half, because the entry is removed by the `show*()`
/// closure that created it, not by the widget. [PopupAnimationController] is
/// the bridge: hold one in `show*()`, hand it to the [PopupAnimator], and call
/// [PopupAnimationController.dismiss] in place of removing the entry directly.
/// It plays the exit and then invokes the teardown.
///
/// Reduce motion is honoured through [HollowDurations.animationsDisabled],
/// which collapses both directions to zero so dismissal stays instant.
class PopupAnimationController {
  _PopupAnimatorState? _state;
  final ValueNotifier<bool> _exiting = ValueNotifier<bool>(false);

  /// Wraps the popup's ENTIRE overlay entry, dismiss barrier included, so it
  /// stops taking pointer events the moment the exit starts.
  ///
  /// Without this a popup keeps swallowing clicks for the length of its exit:
  /// the barrier is still mounted, still full screen, and still on top. The
  /// click that dismisses a picker and a click on the button that reopens it
  /// arrive well inside 140ms of each other, and the second one would land on
  /// a corpse.
  Widget wrapEntry(Widget child) {
    return ValueListenableBuilder<bool>(
      valueListenable: _exiting,
      builder: (_, exiting, inner) =>
          IgnorePointer(ignoring: exiting, child: inner),
      child: child,
    );
  }

  /// Plays the exit, then calls [onDone].
  ///
  /// Falls straight through to [onDone] when no animator is attached (the
  /// popup was torn down before its first frame), so a caller can always
  /// treat this as "remove the entry".
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

  /// Corner the popup grows out of. Anchored popups should point at the
  /// control that opened them.
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

  /// Guards against a second dismiss landing mid-exit (a click on the barrier
  /// while the popup is already closing) restarting the reverse.
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
      // A popup is hit-testable from its first frame (Opacity does not block
      // pointers), so hiding it from assistive tech for the length of the fade
      // would make semantics disagree with what a click already does. It also
      // keeps single-pump widget tests able to find the popup's controls.
      alwaysIncludeSemantics: true,
      child: ScaleTransition(
        scale: _scale,
        alignment: widget.alignment,
        child: widget.child,
      ),
    );
  }
}

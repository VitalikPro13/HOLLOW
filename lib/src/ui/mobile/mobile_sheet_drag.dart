// TransitionRoute.controller is @protected, but driving it externally is the
// framework's own back-swipe mechanism (Cupertino does exactly this from
// inside its library) and there is no public API for the same thing.
// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter/material.dart';

/// Makes a full-screen slide-up sheet draggable: swipe down to pull it with the
/// finger and minimize it, like the iOS back-swipe but vertical.
///
/// It drives the enclosing route's transition controller rather than a local
/// Transform, so the Navigator paints the previous route underneath while the
/// controller sits below 1.0 and the chat shows through as the sheet moves.
/// Routes stay opaque, so a sheet at rest costs no extra paint. The drag is an
/// enhancement only: both call screens keep a labelled Minimize button as the
/// accessible path.
class MobileSheetDragToMinimize extends StatefulWidget {
  final Widget child;

  const MobileSheetDragToMinimize({super.key, required this.child});

  @override
  State<MobileSheetDragToMinimize> createState() =>
      _MobileSheetDragToMinimizeState();
}

class _MobileSheetDragToMinimizeState extends State<MobileSheetDragToMinimize> {
  ModalRoute<dynamic>? _route;
  NavigatorState? _navigator;

  bool get _dragging => _route != null;

  void _onDragStart(DragStartDetails details) {
    final route = ModalRoute.of(context);
    // Only when the route is settled on top, never mid-transition.
    if (route == null ||
        !route.isCurrent ||
        route.controller == null ||
        !route.animation!.isCompleted) {
      return;
    }
    _route = route;
    _navigator = Navigator.of(context);
    _navigator!.didStartUserGesture();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final controller = _route?.controller;
    if (controller == null) return;
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    controller.value =
        (controller.value - (details.primaryDelta ?? 0) / height)
            .clamp(0.0, 1.0);
  }

  void _onDragEnd(DragEndDetails details) {
    final controller = _route?.controller;
    final navigator = _navigator;
    _route = null;
    _navigator = null;
    if (controller == null || navigator == null) return;

    final flingDown = details.velocity.pixelsPerSecond.dy > 700;
    final flingUp = details.velocity.pixelsPerSecond.dy < -300;
    final pastThreshold = controller.value < 0.7;

    if (flingDown || (pastThreshold && !flingUp)) {
      navigator.pop();
    } else if (!controller.isCompleted) {
      controller.forward();
    }
    navigator.didStopUserGesture();
  }

  void _onDragCancel() {
    final controller = _route?.controller;
    final navigator = _navigator;
    _route = null;
    _navigator = null;
    if (controller != null && !controller.isCompleted) controller.forward();
    navigator?.didStopUserGesture();
  }

  @override
  void dispose() {
    // A drag can die with the widget, so the navigator's gesture flag has to be
    // released here too.
    if (_dragging) {
      _navigator?.didStopUserGesture();
      _route = null;
      _navigator = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onDragStart,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      onVerticalDragCancel: _onDragCancel,
      child: widget.child,
    );
  }
}

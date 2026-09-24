import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Transition styles for [hollowMobileRoute].
enum HollowRouteTransition {
  slideRight,

  slideUp,

  fade,
}

/// A [PageRoute] that appears instantly while Reduce Motion is effective, and
/// otherwise uses [transition].
///
/// Use this instead of a bespoke `PageRouteBuilder`, so the reduce-motion gate
/// lives in one place. On iOS a [HollowRouteTransition.slideRight] page can be
/// swiped back from the left edge, and the page below shifts under it.
PageRoute<T> hollowMobileRoute<T>({
  required WidgetBuilder builder,
  HollowRouteTransition transition = HollowRouteTransition.slideRight,
  Duration? duration,
  RouteSettings? settings,
}) {
  return _HollowPageRoute<T>(
    builder: builder,
    transition: transition,
    duration: duration ?? HollowDurations.normal,
    reduce: ReduceMotionController.instance.isReduced,
    settings: settings,
  );
}

/// How far the page below travels while a new page covers it, as a share of
/// the width (iOS moves it about a third).
const double _kParallaxShare = 0.3;

/// Width of the strip along the left edge that starts a swipe back.
const double _kBackGestureWidth = 20;

/// A release faster than this, in widths per second, decides the swipe by its
/// direction instead of by how far it got.
const double _kMinFlingVelocity = 1;

const Duration _kSettleDuration = Duration(milliseconds: 350);

final Animatable<Offset> _kFromRight = Tween<Offset>(
  begin: const Offset(1, 0),
  end: Offset.zero,
);

final Animatable<Offset> _kFromBottom = Tween<Offset>(
  begin: const Offset(0, 1),
  end: Offset.zero,
);

final Animatable<Offset> _kToLeft = Tween<Offset>(
  begin: Offset.zero,
  end: const Offset(-_kParallaxShare, 0),
);

// Tweens rather than CurvedAnimations: transitions rebuild every frame, and
// each CurvedAnimation would leave a status listener on the route's controller.
final Animatable<double> _kEnterCurve = CurveTween(curve: HollowCurves.enter);

class _HollowPageRoute<T> extends PageRoute<T> {
  _HollowPageRoute({
    required this.builder,
    required this.transition,
    required Duration duration,
    required this.reduce,
    super.settings,
  }) : _duration = duration;

  final WidgetBuilder builder;
  final HollowRouteTransition transition;
  final bool reduce;
  final Duration _duration;

  bool get _swipesBack =>
      transition == HollowRouteTransition.slideRight &&
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => reduce ? Duration.zero : _duration;

  @override
  Duration get reverseTransitionDuration => reduce ? Duration.zero : _duration;

  // An instance tear-off, so two stacked pages of this kind never compare
  // equal and the lower one still receives the parallax.
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _swipesBack && !reduce ? _buildCoveredTransition : null;

  Widget? _buildCoveredTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    bool allowSnapshotting,
    Widget? child,
  ) {
    final linear = Navigator.maybeOf(context)?.userGestureInProgress ?? false;
    return SlideTransition(
      position: linear
          ? secondaryAnimation.drive(_kToLeft)
          : secondaryAnimation.drive(_kToLeft.chain(_kEnterCurve)),
      textDirection: Directionality.of(context),
      transformHitTests: false,
      child: child,
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    switch (transition) {
      case HollowRouteTransition.slideRight:
        // The finger drives the page, so it slides even under Reduce motion.
        final dragging = popGestureInProgress;
        final Widget page = SlideTransition(
          position: dragging
              ? animation.drive(_kFromRight)
              : reduce
                  ? const AlwaysStoppedAnimation(Offset.zero)
                  : animation.drive(_kFromRight.chain(_kEnterCurve)),
          child: child,
        );
        if (!_swipesBack) return page;
        return _BackSwipeDetector(
          enabled: () => popGestureEnabled,
          onStart: _startBackSwipe,
          child: page,
        );
      case HollowRouteTransition.slideUp:
        if (reduce) return child;
        return SlideTransition(
          position: animation.drive(_kFromBottom.chain(_kEnterCurve)),
          child: child,
        );
      case HollowRouteTransition.fade:
        if (reduce) return child;
        return FadeTransition(opacity: animation, child: child);
    }
  }

  _BackSwipe _startBackSwipe() => _BackSwipe(
        navigator: navigator!,
        controller: controller!,
        isCurrent: () => isCurrent,
        isActive: () => isActive,
        settle: reduce ? Duration.zero : _kSettleDuration,
      );
}

/// Drives a route's own controller from a swipe, then pops or settles back.
/// Works in route progress: 1 is the page fully on screen, 0 is gone.
class _BackSwipe {
  _BackSwipe({
    required this.navigator,
    required this.controller,
    required this.isCurrent,
    required this.isActive,
    required this.settle,
  }) {
    navigator.didStartUserGesture();
  }

  final NavigatorState navigator;
  final AnimationController controller;
  final ValueGetter<bool> isCurrent;
  final ValueGetter<bool> isActive;
  final Duration settle;

  void update(double delta) => controller.value -= delta;

  void end(double velocity) {
    const curve = Curves.fastEaseInToSlowEaseOut;
    final current = isCurrent();
    final bool stay;
    if (!current) {
      // Popped from elsewhere mid-swipe: follow the stack, not the finger.
      stay = isActive();
    } else if (velocity.abs() >= _kMinFlingVelocity) {
      stay = velocity <= 0;
    } else {
      stay = controller.value > 0.5;
    }

    if (stay) {
      controller.animateTo(1, duration: settle, curve: curve);
    } else {
      if (current) navigator.pop();
      if (controller.isAnimating) {
        controller.animateBack(0, duration: settle, curve: curve);
      }
    }

    // The gesture stays "in progress" until the settle lands, so the
    // transitions keep their linear mapping and do not jump mid-flight.
    if (controller.isAnimating) {
      late AnimationStatusListener onStatus;
      onStatus = (_) {
        navigator.didStopUserGesture();
        controller.removeStatusListener(onStatus);
      };
      controller.addStatusListener(onStatus);
    } else {
      navigator.didStopUserGesture();
    }
  }
}

/// A strip along the leading edge that turns a horizontal drag into a
/// [_BackSwipe]. Pointers that land elsewhere never reach it.
class _BackSwipeDetector extends StatefulWidget {
  const _BackSwipeDetector({
    required this.enabled,
    required this.onStart,
    required this.child,
  });

  final ValueGetter<bool> enabled;
  final ValueGetter<_BackSwipe> onStart;
  final Widget child;

  @override
  State<_BackSwipeDetector> createState() => _BackSwipeDetectorState();
}

class _BackSwipeDetectorState extends State<_BackSwipeDetector> {
  _BackSwipe? _swipe;
  late final HorizontalDragGestureRecognizer _recognizer =
      HorizontalDragGestureRecognizer(debugOwner: this)
        ..onStart = _onStart
        ..onUpdate = _onUpdate
        ..onEnd = _onEnd
        ..onCancel = _onCancel;

  @override
  void dispose() {
    _recognizer.dispose();
    final swipe = _swipe;
    if (swipe != null) {
      // Disposed mid-drag: release the navigator's gesture flag.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (swipe.navigator.mounted) swipe.navigator.didStopUserGesture();
      });
      _swipe = null;
    }
    super.dispose();
  }

  double _logical(double value) =>
      Directionality.of(context) == TextDirection.rtl ? -value : value;

  void _onStart(DragStartDetails _) => _swipe = widget.onStart();

  void _onUpdate(DragUpdateDetails details) =>
      _swipe?.update(_logical(details.primaryDelta! / context.size!.width));

  void _onEnd(DragEndDetails details) {
    _swipe?.end(
      _logical(details.velocity.pixelsPerSecond.dx / context.size!.width),
    );
    _swipe = null;
  }

  void _onCancel() {
    _swipe?.end(0);
    _swipe = null;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.enabled()) _recognizer.addPointer(event);
  }

  @override
  Widget build(BuildContext context) {
    // A notch widens the strip on its side, as iOS does.
    final inset = Directionality.of(context) == TextDirection.rtl
        ? MediaQuery.paddingOf(context).right
        : MediaQuery.paddingOf(context).left;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        PositionedDirectional(
          start: 0,
          width: math.max(inset, _kBackGestureWidth),
          top: 0,
          bottom: 0,
          child: Listener(
            onPointerDown: _onPointerDown,
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';

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
  bool instant = false,
}) {
  return _HollowPageRoute<T>(
    builder: builder,
    transition: transition,
    duration: duration ?? HollowDurations.normal,
    reduce: ReduceMotionController.instance.isReduced,
    instant: instant,
    settings: settings,
  );
}


/// How far the page below travels while a new page covers it, as a share of
/// the width (iOS moves it about a third).
const double _kParallaxShare = 0.3;

/// Width of the strip along the left edge that starts a swipe back.
const double _kBackGestureWidth = 20;

/// How far a drag must carry a page, as a share of the width, for its release
/// to land it; a shorter one settles back where it started.
const double _kCommitShare = 1 / 3;

/// A drag counts as sideways once it is this many times wider than tall, so a
/// scroll that wanders keeps scrolling.
const double _kSidewaysRatio = 1.5;

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
    required this.instant,
    super.settings,
  }) : _duration = duration;

  final WidgetBuilder builder;
  final HollowRouteTransition transition;
  final bool reduce;
  final Duration _duration;

  /// Arrives without a transition (a page slipped in under another, or one
  /// replacing its twin); leaving animates as usual.
  final bool instant;

  /// Set by a [HollowSwipeIn] release: the push picks up where the finger left
  /// its preview.
  double? _startsAt;

  @override
  TickerFuture didPush() {
    final pushed = super.didPush();
    // The value setter stops the clock the push just started.
    final at = _startsAt;
    if (at != null) {
      controller!.value = at;
    } else if (instant) {
      controller!.value = 1;
    }
    return pushed;
  }

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

  _BackSwipe _startBackSwipe() => _drive(stayAbove: 1 - _kCommitShare);

  _BackSwipe _drive({required double stayAbove}) => _BackSwipe(
        navigator: navigator!,
        controller: controller!,
        isCurrent: () => isCurrent,
        isActive: () => isActive,
        settle: reduce ? Duration.zero : _kSettleDuration,
        stayAbove: stayAbove,
      );
}

/// A drag in progress that moves something with the finger. Deltas and
/// velocities are in widths of the page, positive toward the reading end
/// (rightward in a left-to-right layout).
abstract class HollowSwipeDrive {
  void update(double delta);

  /// The finger lifted: land the move or settle back, by [velocity] and
  /// distance.
  void end(double velocity);

  /// The drag's owner went away mid-drag: let go without deciding.
  void release() {}
}

/// Drives a route's own controller from a swipe, then pops or settles back.
/// Works in route progress: 1 is the page fully on screen, 0 is gone.
class _BackSwipe extends HollowSwipeDrive {
  _BackSwipe({
    required this.navigator,
    required this.controller,
    required this.isCurrent,
    required this.isActive,
    required this.settle,
    required this.stayAbove,
  }) {
    navigator.didStartUserGesture();
  }

  final NavigatorState navigator;
  final AnimationController controller;
  final ValueGetter<bool> isCurrent;
  final ValueGetter<bool> isActive;
  final Duration settle;

  /// The progress a slow release must keep for the page to stay.
  final double stayAbove;
  bool _released = false;

  @override
  void update(double delta) => controller.value -= delta;

  @override
  void release() {
    if (_released) return;
    _released = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted) navigator.didStopUserGesture();
    });
  }

  @override
  void end(double velocity) {
    if (_released) return;
    _released = true;
    const curve = Curves.fastEaseInToSlowEaseOut;
    final current = isCurrent();
    final bool stay;
    if (!current) {
      // Popped from elsewhere mid-swipe: follow the stack, not the finger.
      stay = isActive();
    } else if (velocity.abs() >= _kMinFlingVelocity) {
      stay = velocity <= 0;
    } else {
      stay = controller.value > stayAbove;
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
    // Disposed mid-drag: release the navigator's gesture flag.
    _swipe?.release();
    _swipe = null;
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

/// A horizontal drag that only claims a pointer once the move is clearly
/// sideways and in a direction [accepts] takes, so vertical scrolls, long
/// presses and anything nearer the finger win first.
class _PageDragRecognizer extends HorizontalDragGestureRecognizer {
  _PageDragRecognizer({super.debugOwner, required this.accepts})
      // A mouse drag in a narrow desktop window selects text or scrolls; only
      // a finger or a pen moves the page.
      : super(supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
        }) {
    // Winning the arena by default (nothing else under the finger) must
    // still wait for a sideways move in a direction the page takes.
    onlyAcceptDragOnThreshold = true;
    // The slop the finger already moved counts, so the page stays under it.
    dragStartBehavior = DragStartBehavior.down;
  }

  /// Whether a move of this physical horizontal sign may start a drag.
  final bool Function(double dx) accepts;

  final Map<int, Offset> _origins = {};
  Offset _move = Offset.zero;

  /// The physical horizontal distance at the moment the drag was claimed.
  double get claimedDx => _move.dx;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _origins[event.pointer] = event.position;
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    final origin = _origins[event.pointer];
    if (origin != null && event is PointerMoveEvent) {
      _move = event.position - origin;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _origins.remove(event.pointer);
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
      PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) {
    if (!super.hasSufficientGlobalDistanceToAccept(
        pointerDeviceKind, deviceTouchSlop)) {
      return false;
    }
    return _move.dx.abs() > _move.dy.abs() * _kSidewaysRatio &&
        accepts(_move.dx);
  }

  @override
  void dispose() {
    _origins.clear();
    super.dispose();
  }
}


/// A page a leftward drag brings in over the current one. Navigating cancels
/// every pointer down, the dragging finger's too, so nothing is pushed while
/// the finger moves: [preview] slides in under it, and a release past a third
/// (or a flick) pushes [route] exactly where the preview stood.
class HollowSwipeIn {
  const HollowSwipeIn({
    required this.preview,
    required this.route,
    this.onPushed,
  });

  /// What slides in while dragging: the page's own frame, quickly built.
  final WidgetBuilder preview;

  /// The page itself, from [hollowMobileRoute], made once the drag lands.
  final Route<void> Function() route;

  /// Told the push's future (it completes when the page pops).
  final void Function(Future<void> popped)? onPushed;
}

/// Lets a drag that starts anywhere on a [hollowMobileRoute] page move it, on
/// every platform: toward the reading end takes the page back when [back] is
/// set; the other way brings in [swipeIn], or else starts whatever
/// [onSwipeLeft] returns (null = nothing).
///
/// Scrollers, long presses and fields under the finger claim their pointers
/// first; wrap a region that must never start one in
/// [HollowPageSwipeExclusion].
class HollowPageSwipe extends StatefulWidget {
  const HollowPageSwipe({
    super.key,
    required this.child,
    this.back = true,
    this.swipeIn,
    this.onSwipeLeft,
  });

  final Widget child;
  final bool back;
  final HollowSwipeIn? swipeIn;
  final HollowSwipeDrive? Function()? onSwipeLeft;

  @override
  State<HollowPageSwipe> createState() => _HollowPageSwipeState();
}

class _HollowPageSwipeState extends State<HollowPageSwipe>
    with SingleTickerProviderStateMixin {
  late final _PageDragRecognizer _recognizer = _PageDragRecognizer(
    debugOwner: this,
    accepts: _accepts,
  )
    ..onStart = _onStart
    ..onUpdate = _onUpdate
    ..onEnd = _onEnd
    ..onCancel = _onCancel;

  /// How far a [HollowSwipeIn] preview covers this page, 0 to 1.
  late final AnimationController _cover = AnimationController(vsync: this);

  HollowSwipeDrive? _drive;

  /// Pointers a [HollowPageSwipeExclusion] saw land first.
  final Set<int> _excluded = {};

  @override
  void dispose() {
    _recognizer.dispose();
    _drive?.release();
    _drive = null;
    _cover.dispose();
    super.dispose();
  }

  bool get _rtl => Directionality.of(context) == TextDirection.rtl;

  double _logical(double value) => _rtl ? -value : value;

  _HollowPageRoute<dynamic>? get _route {
    final route = ModalRoute.of(context);
    return route is _HollowPageRoute ? route : null;
  }

  bool _accepts(double dx) {
    if (!mounted) return false;
    final route = _route;
    if (route != null && !route.isCurrent) return false;
    if (_logical(dx) > 0) {
      return widget.back && route != null && route.popGestureEnabled;
    }
    return widget.swipeIn != null || widget.onSwipeLeft != null;
  }

  void _onStart(DragStartDetails _) {
    if (_logical(_recognizer.claimedDx) > 0) {
      _drive = _route?._startBackSwipe();
      return;
    }
    final swipeIn = widget.swipeIn;
    _drive = swipeIn != null
        ? _SwipeInDrive(this, swipeIn)
        : widget.onSwipeLeft?.call();
  }

  void _onUpdate(DragUpdateDetails details) =>
      _drive?.update(_logical(details.primaryDelta! / context.size!.width));

  void _onEnd(DragEndDetails details) {
    _drive?.end(
      _logical(details.velocity.pixelsPerSecond.dx / context.size!.width),
    );
    _drive = null;
  }

  void _onCancel() {
    _drive?.end(0);
    _drive = null;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_excluded.remove(event.pointer)) return;
    _recognizer.addPointer(event);
  }

  @override
  Widget build(BuildContext context) {
    // While a preview covers the page it shifts under it, as it will once the
    // pushed page takes over (iOS only, like the route's own parallax).
    final parallax = defaultTargetPlatform == TargetPlatform.iOS &&
        !ReduceMotionController.instance.isReduced;
    return Listener(
      onPointerDown: _onPointerDown,
      behavior: HitTestBehavior.translucent,
      child: !parallax
          ? widget.child
          : AnimatedBuilder(
              animation: _cover,
              builder: (context, child) => FractionalTranslation(
                translation: Offset(
                    (_rtl ? 1 : -1) * _kParallaxShare * _cover.value, 0),
                child: child,
              ),
              child: widget.child,
            ),
    );
  }
}

/// A [HollowSwipeIn] in progress: the preview follows the finger in the
/// navigator's overlay; the release pushes the page or slides the preview out.
class _SwipeInDrive extends HollowSwipeDrive {
  _SwipeInDrive(this.host, this.swipeIn) {
    final overlay = Navigator.of(host.context).overlay;
    _entry = OverlayEntry(builder: _buildPreview);
    overlay?.insert(_entry!);
    // A raw entry outlives every route pushed above it: the lock clears it
    // before its cover rises.
    OverlayHosts.register(this, release);
    host._cover.value = 0;
  }

  final _HollowPageSwipeState host;
  final HollowSwipeIn swipeIn;
  OverlayEntry? _entry;
  bool _done = false;

  Widget _buildPreview(BuildContext context) {
    final rtl = Directionality.of(host.context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation: host._cover,
      builder: (context, child) => FractionalTranslation(
        translation: Offset((rtl ? -1 : 1) * (1 - host._cover.value), 0),
        child: child,
      ),
      child: Builder(builder: swipeIn.preview),
    );
  }

  @override
  void update(double delta) {
    if (_done || !host.mounted) return;
    host._cover.value -= delta;
  }

  void _removePreview() {
    OverlayHosts.unregister(this);
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  /// Also what the lock calls, so it takes the preview down even while a
  /// settle is still sliding it out.
  @override
  void release() {
    _done = true;
    _removePreview();
    if (host.mounted) host._cover.value = 0;
  }

  @override
  void end(double velocity) {
    if (_done || !host.mounted) {
      release();
      return;
    }
    final hostRoute = host._route;
    if (hostRoute != null && !hostRoute.isCurrent) {
      // A route pushed over the page mid-drag (the lock cover, a call, a
      // dialog) cancelled the finger: it stays on top, nothing lands under it.
      release();
      return;
    }
    _done = true;
    final cover = host._cover;
    final land = velocity.abs() >= _kMinFlingVelocity
        ? velocity < 0
        : cover.value > _kCommitShare;
    if (!land) {
      final settle =
          host._route?.reduce ?? false ? Duration.zero : _kSettleDuration;
      if (settle == Duration.zero || cover.value == 0) {
        cover.value = 0;
        _removePreview();
        return;
      }
      cover
          .animateBack(0, duration: settle, curve: Curves.fastEaseInToSlowEaseOut)
          .whenCompleteOrCancel(_removePreview);
      return;
    }
    final navigator = Navigator.of(host.context);
    final route = swipeIn.route() as _HollowPageRoute<void>;
    route._startsAt = cover.value;
    final popped = navigator.push(route);
    swipeIn.onPushed?.call(popped);
    // The pushed page stands where the preview did; its own parallax takes
    // over the page below in the same frame.
    _removePreview();
    cover.value = 0;
    route._drive(stayAbove: 0).end(0);
  }
}

/// A region (a composer, a text field) where a sideways drag belongs to what
/// is inside, never to the [HollowPageSwipe] around it.
class HollowPageSwipeExclusion extends StatelessWidget {
  const HollowPageSwipeExclusion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
        // Nearer the finger than the swipe's own listener, so it runs first.
        onPointerDown: (event) => context
            .findAncestorStateOfType<_HollowPageSwipeState>()
            ?._excluded
            .add(event.pointer),
        behavior: HitTestBehavior.translucent,
        child: child,
      );
}

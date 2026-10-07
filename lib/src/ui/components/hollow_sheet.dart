// TransitionRoute.controller is @protected, but a sheet pulled by the finger
// has to drive its own route's controller; there is no public API for it.
// ignore_for_file: invalid_use_of_protected_member

import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// The height cap of a tall sheet (a profile, a game card, the expression
/// picker): the strip left above it shows what it covers and is where a tap
/// closes it.
const double kSheetTallHeightFactor = 0.85;

/// The one bottom sheet: the floating surface, the sheet radius on its top
/// corners, and the drag handle, so no call site styles its own.
///
/// A downward drag anywhere on the sheet pulls it with the finger and closes
/// it, including a pull that starts at the top of scrolled content: content
/// scrolls back to its top first, then the sheet follows.
///
/// [scrollControlled] lets the sheet grow past Flutter's 9/16 height cap, for
/// content that can be tall (an emoji grid, a long action list); the builder
/// then bounds itself, usually with a `ConstrainedBox` on a share of the
/// screen height.
///
/// [handle] is false only when the builder places [HollowSheetHandle] itself,
/// as a `DraggableScrollableSheet` must, so the handle drags with the content.
///
/// [maxHeightFactor] caps the WHOLE sheet, handle included, at that share of
/// the screen height.
Future<T?> showHollowSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool scrollControlled = false,
  double? maxHeightFactor,
  bool handle = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  RouteSettings? routeSettings,
}) {
  final hollow = HollowTheme.of(context);
  return showModalBottomSheet<T>(
    context: context,
    // The surface is painted inside the builder from the sheet's own context,
    // so a theme change while the sheet is open repaints it too.
    backgroundColor: Colors.transparent,
    barrierColor: hollow.scrim,
    isScrollControlled: scrollControlled,
    isDismissible: isDismissible,
    // The sheet's own drag would lose every pull that starts on scrolling
    // content; [_SheetPullScope] takes both kinds instead.
    enableDrag: false,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    clipBehavior: Clip.antiAlias,
    sheetAnimationStyle: _sheetMotion(),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (sheetContext) {
      Widget sheet = ColoredBox(
        color: HollowTheme.of(sheetContext).overlay,
        child: handle
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const HollowSheetHandle(),
                  Flexible(child: builder(sheetContext)),
                ],
              )
            : builder(sheetContext),
      );
      if (maxHeightFactor != null) {
        sheet = ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * maxHeightFactor,
          ),
          child: sheet,
        );
      }
      return enableDrag ? _SheetPullScope(child: sheet) : sheet;
    },
  );
}

/// The sheet's one curve, both ways and under Reduce motion too: a pull maps
/// the finger onto the route's controller through it.
const Curve _kSheetCurve = HollowCurves.enter;

/// Read per open, so Reduce motion reaches the next sheet. A reverse curve runs
/// backwards, so the enter curve doubles as the easing-in exit.
AnimationStyle _sheetMotion() {
  if (HollowDurations.animationsDisabled) {
    return const AnimationStyle(
      curve: _kSheetCurve,
      reverseCurve: _kSheetCurve,
      duration: Duration.zero,
      reverseDuration: Duration.zero,
    );
  }
  return AnimationStyle(
    curve: _kSheetCurve,
    reverseCurve: _kSheetCurve,
    duration: HollowDurations.normal,
    reverseDuration: HollowDurations.fast,
  );
}

/// A downward fling faster than this closes the sheet wherever it was let go.
const double _kSheetFlingVelocity = 700;

/// Let go after pulling the sheet down by more than this share of its height
/// and it closes; less and it settles back.
const double _kSheetCloseShare = 0.25;

/// Pulls the sheet with the finger and closes it on release: from a drag on
/// content that does not scroll, and through [_SheetPullPhysics] from a pull
/// past the top of content that does.
///
/// It drives the route's own controller, so the scrim fades with the pull and
/// a close runs the normal exit from wherever the sheet was let go.
class _SheetPullScope extends StatefulWidget {
  final Widget child;

  const _SheetPullScope({required this.child});

  @override
  State<_SheetPullScope> createState() => _SheetPullScopeState();
}

class _SheetPullScopeState extends State<_SheetPullScope> {
  _SheetPullPhysics? _physics;

  /// The route being pulled; null when no pull is under way.
  ModalRoute<Object?>? _route;

  /// How far the sheet sits below its resting place, in pixels.
  double _offset = 0;

  bool get _pulled => _offset > 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // One instance for the sheet's life: a new physics object would rebuild
    // every scroll position under it, and that ends a drag in progress.
    _physics ??= _SheetPullPhysics(
      this,
      parent: ScrollConfiguration.of(context).getScrollPhysics(context),
    );
  }

  @override
  void dispose() {
    final controller = _route?.controller;
    if (controller != null && _route!.isActive && !controller.isCompleted) {
      controller.forward();
    }
    super.dispose();
  }

  /// Moves the sheet by [delta] pixels, positive downward, and returns what is
  /// left over once it is back at rest, for the content to scroll with.
  double _pull(double delta) {
    var route = _route;
    if (route == null) {
      if (delta <= 0) return delta;
      route = ModalRoute.of(context);
      // Only a sheet settled on top, never one still opening or closing.
      if (route == null ||
          !route.isCurrent ||
          route.controller == null ||
          !route.animation!.isCompleted) {
        return delta;
      }
      _route = route;
    }
    final height = context.size?.height ?? 0;
    if (height <= 0) return delta;
    final next = _offset + delta;
    _offset = next.clamp(0.0, height);
    if (_offset == 0) {
      route.controller!.value = 1;
      _route = null;
      return next;
    }
    route.controller!.value = _valueFor(_offset / height);
    return 0;
  }

  /// Ends a pull: closes on a downward fling or a long enough pull, otherwise
  /// settles back. [downVelocity] is in pixels per second, positive downward.
  void _release(double downVelocity) {
    final route = _route;
    final offset = _offset;
    _route = null;
    _offset = 0;
    final controller = route?.controller;
    if (route == null || controller == null) return;
    final height = context.size?.height ?? 0;
    final close = downVelocity > _kSheetFlingVelocity ||
        (downVelocity > -_kSheetFlingVelocity &&
            offset > height * _kSheetCloseShare);
    if (close && route.isCurrent) {
      route.navigator?.pop();
    } else if (!controller.isCompleted) {
      controller.forward();
    }
  }

  /// The controller value that shows the sheet [pulledShare] of its height
  /// below rest, through the curve the route animates with.
  static double _valueFor(double pulledShare) {
    final target = 1 - pulledShare;
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 24; i++) {
      final mid = (lo + hi) / 2;
      if (_kSheetCurve.transform(mid) < target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (d) => _pull(d.primaryDelta ?? 0),
      onVerticalDragEnd: (d) => _release(d.primaryVelocity ?? 0),
      onVerticalDragCancel: () => _release(0),
      child: NotificationListener<ScrollEndNotification>(
        // A scrollable whose own physics never asks its parent for a fling
        // still ends its drag here.
        onNotification: (n) {
          if (_route != null) _release(n.dragDetails?.primaryVelocity ?? 0);
          return false;
        },
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(physics: _physics),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Hands a downward drag at the top of the sheet's content to the sheet, and
/// an upward one back to the sheet first while it is pulled down.
class _SheetPullPhysics extends ScrollPhysics {
  final _SheetPullScopeState _scope;

  const _SheetPullPhysics(this._scope, {super.parent});

  @override
  _SheetPullPhysics applyTo(ScrollPhysics? ancestor) =>
      _SheetPullPhysics(_scope, parent: buildParent(ancestor));

  bool _handles(ScrollMetrics position) =>
      position.axisDirection == AxisDirection.down;

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (_handles(position) &&
        (_scope._pulled ||
            (offset > 0 && position.pixels <= position.minScrollExtent))) {
      final rest = _scope._pull(offset);
      if (rest == 0) return 0;
      return super.applyPhysicsToUserOffset(position, rest);
    }
    return super.applyPhysicsToUserOffset(position, offset);
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    if (_handles(position) && _scope._route != null) {
      final pulled = _scope._pulled;
      // Scroll velocity runs opposite to the finger on a downward axis.
      _scope._release(-velocity);
      // A fling that ends a pull belongs to the sheet, not the content.
      if (pulled) return super.createBallisticSimulation(position, 0);
    }
    return super.createBallisticSimulation(position, velocity);
  }
}

/// The grab bar at the top of a sheet, with the gap below it.
class HollowSheetHandle extends StatelessWidget {
  const HollowSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      child: Center(
        child: Container(
          width: _handleWidth,
          height: _handleHeight,
          decoration: BoxDecoration(
            color: hollow.border,
            borderRadius: BorderRadius.circular(HollowRadius.pill),
          ),
        ),
      ),
    );
  }
}

const double _handleWidth = 32;
const double _handleHeight = 4;

/// The name at the top of a phone action sheet (the person, server, channel or
/// message the rows act on): start-aligned `subheading`, one line.
class HollowSheetTitle extends StatelessWidget {
  final String title;

  /// A quiet second line, such as what kind of thing the title names.
  final String? subtitle;

  const HollowSheetTitle(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Full width, so a sheet whose column centres its children still starts
    // the title on the rows' leading edge.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.lg, 0, HollowSpacing.lg, HollowSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: HollowTypography.subheading.copyWith(color: hollow.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

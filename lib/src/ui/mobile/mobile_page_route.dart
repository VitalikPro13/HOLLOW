import 'package:flutter/material.dart';

import 'package:hollow/src/core/reduce_motion.dart';

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
/// lives in one place.
PageRoute<T> hollowMobileRoute<T>({
  required WidgetBuilder builder,
  HollowRouteTransition transition = HollowRouteTransition.slideRight,
  Duration duration = const Duration(milliseconds: 250),
  RouteSettings? settings,
}) {
  final reduce = ReduceMotionController.instance.isReduced;
  return PageRouteBuilder<T>(
    settings: settings,
    transitionDuration: reduce ? Duration.zero : duration,
    reverseTransitionDuration: reduce ? Duration.zero : duration,
    pageBuilder: (context, _, __) => builder(context),
    transitionsBuilder: (context, anim, _, child) {
      if (reduce) return child;
      switch (transition) {
        case HollowRouteTransition.slideRight:
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
            child: child,
          );
        case HollowRouteTransition.slideUp:
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
            child: child,
          );
        case HollowRouteTransition.fade:
          return FadeTransition(opacity: anim, child: child);
      }
    },
  );
}

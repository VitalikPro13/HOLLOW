import 'package:flutter/material.dart';

/// Shares the master startup animation controller with the subtree.
///
/// Both accessors return null once the reveal is complete, which is the signal
/// to render fully and skip the wrapping.
class StartupRevealScope extends InheritedWidget {
  final AnimationController controller;
  final bool isComplete;

  const StartupRevealScope({
    super.key,
    required this.controller,
    required this.isComplete,
    required super.child,
  });

  /// Returns the startup animation controller, or null once it is complete.
  static AnimationController? of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<StartupRevealScope>();
    if (scope == null || scope.isComplete) return null;
    return scope.controller;
  }

  /// Returns a [CurvedAnimation] over a sub-interval of the master timeline,
  /// or null once the reveal is complete.
  static Animation<double>? interval(
    BuildContext context,
    double begin,
    double end, {
    Curve curve = Curves.easeOutCubic,
  }) {
    final controller = of(context);
    if (controller == null) return null;
    return CurvedAnimation(
      parent: controller,
      curve: Interval(begin, end, curve: curve),
    );
  }

  @override
  bool updateShouldNotify(StartupRevealScope oldWidget) =>
      isComplete != oldWidget.isComplete;
}

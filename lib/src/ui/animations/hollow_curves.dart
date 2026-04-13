import 'package:flutter/animation.dart';

/// Standard animation curves for Hollow UI.
abstract final class HollowCurves {
  /// Default enter curve — snappy with a small overshoot.
  static const enter = Curves.easeOutCubic;

  /// Default exit curve — smooth deceleration.
  static const exit = Curves.easeInCubic;

  /// Spring curve for interactive elements (buttons, cards).
  static const spring = Curves.elasticOut;

  /// Subtle ease for hover/focus transitions.
  static const subtle = Curves.easeInOut;
}

/// Standard animation durations for Hollow UI.
///
/// When [animationsDisabled] is true, all durations return [Duration.zero]
/// so every animated widget snaps instantly.
abstract final class HollowDurations {
  static bool _disabled = false;

  static set animationsDisabled(bool value) => _disabled = value;
  static bool get animationsDisabled => _disabled;

  /// Quick transitions (hover, focus, status changes).
  static Duration get fast =>
      _disabled ? Duration.zero : const Duration(milliseconds: 150);

  /// Standard transitions (panels, dialogs).
  static Duration get normal =>
      _disabled ? Duration.zero : const Duration(milliseconds: 250);

  /// Longer transitions (page changes, layout shifts).
  static Duration get slow =>
      _disabled ? Duration.zero : const Duration(milliseconds: 400);
}

import 'package:flutter/animation.dart';

/// Standard animation curves for Hollow UI.
abstract final class HollowCurves {
  static const enter = Curves.easeOutCubic;

  static const exit = Curves.easeInCubic;

  static const spring = Curves.elasticOut;

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

  static Duration get fast =>
      _disabled ? Duration.zero : const Duration(milliseconds: 150);

  static Duration get normal =>
      _disabled ? Duration.zero : const Duration(milliseconds: 250);

  static Duration get slow =>
      _disabled ? Duration.zero : const Duration(milliseconds: 400);
}

import 'package:flutter/animation.dart';

/// Standard animation curves for Hollow UI. Nothing overshoots: no spring, no
/// bounce, no elastic.
abstract final class HollowCurves {
  static const enter = Curves.easeOutCubic;

  static const exit = Curves.easeInCubic;

  static const subtle = Curves.easeInOut;
}

/// Standard animation durations for Hollow UI.
///
/// When [animationsDisabled] is true, all durations return [Duration.zero]
/// so every animated widget snaps instantly. Read them in `build` (or when a
/// controller starts), never once in `initState`, so a live Reduce motion
/// change reaches widgets that are already on screen.
abstract final class HollowDurations {
  static bool _disabled = false;

  static set animationsDisabled(bool value) => _disabled = value;
  static bool get animationsDisabled => _disabled;

  /// Something leaving: a popover, a tooltip, a toast. Exits are quicker than
  /// entrances because nobody waits to watch a thing go.
  static Duration get exit =>
      _disabled ? Duration.zero : const Duration(milliseconds: 100);

  static Duration get fast =>
      _disabled ? Duration.zero : const Duration(milliseconds: 150);

  static Duration get normal =>
      _disabled ? Duration.zero : const Duration(milliseconds: 250);

  static Duration get slow =>
      _disabled ? Duration.zero : const Duration(milliseconds: 400);
}

/// The one motion for things that arrive on top of the app (design language
/// 3.8): popovers, pickers, toasts, notification cards.
abstract final class HollowMotion {
  /// How far anything travels on its way in, whatever its size. A scale is
  /// measured the same way: a big panel scaled from 0.94 moves its far corner
  /// 25 px, which reads as a stretchy slide, so big panels rise instead.
  static const double rise = 8;

  /// A small popover (a menu, a card) grows from its trigger at this scale.
  static const double popoverScale = 0.96;
}

import 'package:flutter/widgets.dart';

/// Largest connected display in PHYSICAL pixels, the best a viewer could show
/// a screen share at; rides the screen_watch signal so the sharer clamps.
///
/// Read via platformDispatcher, NOT MediaQuery: below the UiScale transform
/// MediaQuery geometry is the scaled logical SLOT. (0, 0) means unknown.
(int, int) largestDisplayResolution() {
  int bestW = 0, bestH = 0;
  for (final d in WidgetsBinding.instance.platformDispatcher.displays) {
    final w = d.size.width.round();
    final h = d.size.height.round();
    if (w * h > bestW * bestH) {
      bestW = w;
      bestH = h;
    }
  }
  return (bestW, bestH);
}

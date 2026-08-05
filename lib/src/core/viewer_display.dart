import 'package:flutter/widgets.dart';

/// Largest connected display in PHYSICAL pixels — the best a viewer could
/// ever show a screen share at (media forwarding step 1: this rides the
/// screen_watch signal so the sharer clamps our encoder to it).
///
/// Read via platformDispatcher, NOT MediaQuery: below the UiScale transform
/// MediaQuery geometry is the scaled logical SLOT, not the panel. Returns
/// (0, 0) when the platform reports no displays; receivers treat that as
/// "unknown" and skip the viewer clamp (same as an old client).
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

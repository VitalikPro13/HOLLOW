import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/annotation_mode_provider.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';

/// Height of the band the floating window chrome covers along the top of a
/// full-window route (the window controls, and macOS's traffic lights), in the
/// route's own logical pixels; 0 when it is hidden.
///
/// Content in that band moves DOWN by this, whole row at once, keeping its
/// margins even on every side, never squeezed sideways around the controls.
/// Zero while the Dock does not own the chrome, and in fullscreen or
/// annotation, where the controls are hidden.
double windowChromeTop(WidgetRef ref) {
  final shown = ref.watch(dockOwnsWindowChromeProvider) &&
      !ref.watch(fullscreenProvider) &&
      !ref.watch(annotationModeProvider);
  // The header is kDockHeaderHeight tall at any zoom, measured in the zoomed
  // coordinates a route inside the scaled viewport lays out in.
  return shown ? kDockHeaderHeight : 0;
}

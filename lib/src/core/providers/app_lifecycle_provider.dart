import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Current app lifecycle state (mobile), fed from the shell's
/// `didChangeAppLifecycleState`. It decides where a freshly-received message
/// surfaces: the in-app banner when resumed, a real OS notification otherwise,
/// because in-app banners can't draw while backgrounded even though the WS
/// node is still connected. Starts from what the engine last reported (an app a
/// push launched into the background is not on screen), else `resumed`.
final appLifecycleProvider =
    StateProvider<AppLifecycleState>((ref) => _initialLifecycle());

AppLifecycleState _initialLifecycle() {
  try {
    return WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  } catch (_) {
    return AppLifecycleState.resumed;
  }
}

/// True when the app is not in the foreground (mobile). A message arriving now
/// should post an OS notification rather than an in-app banner.
extension AppLifecycleX on AppLifecycleState {
  bool get isBackground =>
      this == AppLifecycleState.paused ||
      this == AppLifecycleState.inactive ||
      this == AppLifecycleState.hidden ||
      this == AppLifecycleState.detached;
}

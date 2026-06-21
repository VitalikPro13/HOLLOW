import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Current app lifecycle state (mobile). Fed from the shell's
/// `didChangeAppLifecycleState`. Used to decide where a freshly-received message
/// should surface:
/// - **resumed** → the in-app banner (the user is looking at the app).
/// - **paused / inactive / hidden** → a real OS notification, because in-app
///   banners can't show while the app is backgrounded (the live WS node is still
///   connected, so we DO receive the message — we just can't draw on screen).
///
/// Defaults to `resumed` so desktop and pre-init mobile behave as "foreground".
final appLifecycleProvider =
    StateProvider<AppLifecycleState>((ref) => AppLifecycleState.resumed);

/// True when the app is not in the foreground (mobile). A message arriving now
/// should post an OS notification rather than an in-app banner.
extension AppLifecycleX on AppLifecycleState {
  bool get isBackground =>
      this == AppLifecycleState.paused ||
      this == AppLifecycleState.inactive ||
      this == AppLifecycleState.hidden ||
      this == AppLifecycleState.detached;
}

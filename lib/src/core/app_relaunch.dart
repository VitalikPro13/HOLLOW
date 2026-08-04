import 'dart:io';

import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

/// Shut the node down and restart the app.
///
/// Two traps make the obvious approaches fail, both found the hard way:
/// - Spawning a fresh copy BEFORE exiting dies on Windows: the native
///   runner's `SendAppLinkToInstance()` runs pre-Flutter in the child, finds
///   our still-alive window (same exe path), forwards, and exits.
/// - A waiter process can't be spawned from Dart either: detached mode kills
///   powershell instantly (no console, and Dart exposes no CREATE_NO_WINDOW),
///   while a detached cmd batch wedges its `tasklist | find` loop in a
///   half-alive console (frozen `find "<pid>"` window).
///
/// So the waiter is spawned by Rust (`spawn_relaunch_waiter`, updater.rs)
/// with CREATE_NO_WINDOW: it idles until our pid is gone, then starts the
/// exe. On mobile there is no self-relaunch — we just exit and the user
/// reopens the app.
///
/// Never returns (ends in `exit(0)`); never throws — a relaunch failure
/// still exits, matching the old best-effort behavior.
Future<Never> relaunchApp() async {
  try {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // Spawn the waiter FIRST: it only watches our pid, and doing it before
      // the node shutdown keeps the restart alive even if shutdown hangs.
      await updater_api.spawnRelaunchWaiter();
    }
  } catch (_) {}
  try {
    await network_api.notifyShutdown();
    await Future<void>.delayed(const Duration(milliseconds: 200));
  } catch (_) {}
  exit(0);
}

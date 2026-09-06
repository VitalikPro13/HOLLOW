import 'dart:io';

import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

/// Shut the node down and restart the app.
///
/// The waiter is spawned by RUST (`spawn_relaunch_waiter`, updater.rs) with
/// CREATE_NO_WINDOW: it idles until our pid is gone, then starts the exe.
/// Neither obvious alternative works. Spawning a fresh copy BEFORE exiting
/// dies on Windows, where the native runner's `SendAppLinkToInstance()` finds
/// our still-alive window and forwards; and Dart cannot spawn the waiter
/// itself (detached powershell dies instantly, a detached cmd batch wedges).
///
/// Mobile has no self-relaunch: it exits and the user reopens. Never returns
/// (ends in `exit(0)`) and never throws.
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

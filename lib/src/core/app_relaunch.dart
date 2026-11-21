import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

/// What the app does before it ends its own process. The shell points it at
/// `hangUpBeforeExit`, so the people in a call hear a hangup rather than a
/// connection that just stops (#146).
Future<void> Function()? beforeAppExit;

/// Runs [beforeAppExit] once. Never throws; a hook that wedges is cut off.
Future<void> runBeforeAppExit() async {
  final hook = beforeAppExit;
  beforeAppExit = null;
  if (hook == null) return;
  try {
    await hook().timeout(const Duration(seconds: 4));
  } catch (_) {}
}

/// Ends the process after [runBeforeAppExit]: the one way a running app
/// exits on its own.
Future<Never> exitApp([int code = 0]) async {
  await runBeforeAppExit();
  exit(code);
}

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
  await runBeforeAppExit();
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

/// Pins [path] as the active profile and restarts onto it. Pinned even for the
/// Default profile: the pin has to beat portable auto-detection on the way back.
Future<Never> switchProfileAndRestart(String path) async {
  await saveProfileRegistry(
      readProfileRegistrySync().copyWith(activePath: path));
  return relaunchApp();
}

/// Ends the process for a relay change, the one exit every relay switch takes.
///
/// The node binds its relay at startup, so a change only lands on a fresh
/// process; mobile has no self-relaunch and the user reopens. [endProcess]: an
/// Android screen that only closes keeps the process and its open store, and
/// the next launch's wipe of a link's throwaway must not run beneath them.
Future<void> exitForRelaySwitch({bool endProcess = false}) async {
  await runBeforeAppExit();
  if (endProcess) await relaunchApp();
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await network_api.notifyShutdown();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await SystemNavigator.pop();
    return;
  }
  await relaunchApp();
}

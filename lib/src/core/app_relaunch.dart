import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
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
/// Mobile has no self-relaunch: it exits and the user reopens (an iOS relay
/// switch never comes here, see [RelaySwitchEnd]). Never returns
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

/// How a relay switch ends the running app, which it has to: the node binds
/// its relay at startup, so a change only lands on a fresh process.
enum RelaySwitchEnd {
  /// A desktop restarts itself onto the new relay.
  restart,

  /// Android ends the process, and the person opens Hollow again.
  close,

  /// iOS gives an app no sanctioned way to quit (`exit` reads as a crash and
  /// `SystemNavigator.pop` does nothing there), so the relay waits for the
  /// next launch and the person closes Hollow from the app switcher.
  closeByHand,
}

/// Stands in for the platform in tests.
@visibleForTesting
RelaySwitchEnd? debugRelaySwitchEnd;

RelaySwitchEnd get relaySwitchEnd =>
    debugRelaySwitchEnd ??
    (Platform.isIOS
        ? RelaySwitchEnd.closeByHand
        : Platform.isAndroid
            ? RelaySwitchEnd.close
            : RelaySwitchEnd.restart);

/// Moves this install to [domain], the one path every relay switch takes:
/// saved for the next launch and listed, then the app ends so the node
/// starts on it. Until that launch, this process and the push fetch stay on
/// the relay it runs on.
///
/// False where the person closes the app ([RelaySwitchEnd.closeByHand]):
/// [domain] then waits in [pendingRelayProvider], and this process, its calls
/// included, keeps running. [endProcess] ends it there too: a linking
/// device's throwaway must not stay open beneath the next launch's wipe.
Future<bool> switchRelay(
    T Function<T>(ProviderListenable<T>) read, String domain,
    {bool endProcess = false}) async {
  await read(relayDomainProvider.notifier).saveForNextLaunch(domain);
  await read(savedRelayListProvider.notifier).addRelay(domain);
  if (!endProcess && relaySwitchEnd == RelaySwitchEnd.closeByHand) {
    return false;
  }
  return exitForRelaySwitch();
}

/// Ends the process for a relay change; only [switchRelay] calls it.
///
/// Android exits as well, never only closing its screen: a closed screen keeps
/// the process, its open store and a node bound to the old relay, so the app
/// opened again came up with "Node is already running" and no connection.
Future<Never> exitForRelaySwitch() async {
  await runBeforeAppExit();
  return relaunchApp();
}

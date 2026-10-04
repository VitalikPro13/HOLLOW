import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/crash_log.dart';
import 'package:hollow/src/core/duress_result.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/core/services/desktop_notification_service.dart';
import 'package:hollow/src/core/services/push_hints_cache.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:path_provider/path_provider.dart';

export 'package:hollow/src/core/duress_result.dart';

/// Local clean-up that follows a wipe, before the app relaunches to Welcome:
/// what Hollow keeps outside the Rust data root, the OS keystore secrets, the
/// OS notification history and the push registration. Nothing here waits on
/// the network, because the duress path wipes before the node ever starts.
Future<void> clearLocalSecretsAfterDestroy() async {
  await CrashLog.erase();
  try {
    await AppLockService().clearAll();
  } catch (e) {
    debugPrint('[HOLLOW] destroy: app lock clear failed: $e');
  }
  await forgetPushRegistration();
  try {
    await PushHintsCache.forget();
  } catch (_) {}
  if (DesktopNotificationService.isSupported) {
    unawaited(DesktopNotificationService.instance.clearAll());
  }
  await _emptyAppTempDirs();
  try {
    await network_api
        .unregisterPushToken()
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint('[HOLLOW] destroy: push unregister skipped: $e');
  }
}

/// Whether this profile's wipe left work for the next launch. Swappable in tests.
@visibleForTesting
Future<bool> Function() wipeUnfinished = storage_api.hasPendingWipe;

/// How a wipe restarts the app. Swappable in tests.
@visibleForTesting
Future<Never> Function() relaunchForWipe = relaunchApp;

/// Every wipe restarts through here, because a wipe touches only its own
/// profile. A finished one makes the profile list forget this profile first, so
/// Hollow opens another profile or Welcome; an unfinished one restarts into the
/// same profile, whose boot wipe finishes the job before the list moves on.
Future<Never> relaunchAfterWipe() async {
  try {
    if (!await wipeUnfinished()) await forgetWipedProfile(runningProfileRoot());
  } catch (_) {}
  return relaunchForWipe();
}

/// A boot wipe that just finished destroying this profile: the profile list
/// forgets it, and Hollow restarts when the next launch opens another profile.
Future<void> settleProfileAfterBootWipe() async {
  final root = runningProfileRoot();
  await forgetWipedProfile(root);
  if (nextLaunchLeaves(root)) await relaunchForWipe();
}

/// A launch that finds no identity on a phone: a wipe the push extension or
/// the background fetch ran never reached this clean-up, so its leftovers go
/// now, without stopping anything the next identity will need.
Future<void> clearTracesOfAGoneIdentity() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  await forgetPushRegistration(quiet: false);
  try {
    await PushHintsCache.forget(stopWriting: false);
  } catch (_) {}
}

/// Phones keep picker copies, pack exports and staged media in temp folders
/// private to the app, so they are emptied whole.
Future<void> _emptyAppTempDirs() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  final dirs = <Directory>[];
  try {
    dirs.add(await getTemporaryDirectory());
  } catch (_) {}
  if (Platform.isIOS) dirs.add(Directory.systemTemp);
  for (final dir in dirs) {
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        try {
          entity.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }
}

/// What a duress code typed at a Settings prompt does next. Swappable in tests.
@visibleForTesting
Future<Never> Function() onDuressAtPrompt = endSessionAfterDuress;

/// Ends the session after a duress code exactly as the launch prompt does:
/// nothing on screen says anything, the local secrets go, and the app starts
/// over (a phone closes). Never returns.
Future<Never> endSessionAfterDuress() async {
  await clearLocalSecretsAfterDestroy();
  return relaunchAfterWipe();
}

/// Every Settings call that takes a typed password goes through here. A duress
/// code typed at any of them has already wiped the data in Rust, so the dialog
/// keeps its spinner, hears no error, and the session ends.
Future<T> withTypedSecret<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (e) {
    if (isDuressResult(e)) await onDuressAtPrompt();
    rethrow;
  }
}

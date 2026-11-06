import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';

/// Finishes a wipe the last session left, a link's unlanded throwaway among
/// them; a finished destroy also takes this profile off the profile list. Says
/// nothing either way.
Future<void> finishBootWipe() async {
  try {
    await storage_api.settleLinkThrowaway();
  } catch (_) {}
  try {
    if (await storage_api.hasPendingWipe()) {
      if (await storage_api.performPendingWipe()) {
        await settleProfileAfterBootWipe();
      }
    }
  } catch (e) {
    debugPrint('[HOLLOW] Pending data-dir wipe failed: $e');
  }
}

/// The first-run "Link a device" launch on its throwaway identity: [startUp]
/// runs the launch up to the node (false when it stopped short), then the
/// enter-code dialog opens once [keyPrompt] (the relay's key prompt, if open)
/// is answered, or it would cover the prompt.
///
/// Only a landed link stays in this process: it restarts Hollow itself. Every
/// other way out (Back, a closed dialog, an unanswered key prompt, an error)
/// goes back to Welcome through [abandon], never on into the app on an account
/// the next launch wipes (#123).
Future<void> runFirstRunLink(
  BuildContext context, {
  required Future<bool> Function() startUp,
  required Future<void>? Function() keyPrompt,
  Future<void> Function() abandon = abandonFirstRunLink,
}) async {
  try {
    if (await startUp() && context.mounted) {
      await keyPrompt();
      if (context.mounted) {
        dismissConnectingDialog();
        await showDeviceLinkDialog(context, mode: DeviceLinkMode.enterCode);
      }
    }
  } catch (e) {
    unawaited(network_api
        .logFromDart(message: '[HOLLOW-LINK] The link stopped short: $e')
        .catchError((_) {}));
  } finally {
    await abandon();
  }
}

/// Back to Welcome: the running node still holds the throwaway's database, so
/// the wipe is queued for the next launch, which runs before the node starts
/// (an open SQLCipher file survives a delete on Windows).
Future<void> abandonFirstRunLink() async {
  try {
    await storage_api.stashPendingWipe();
  } catch (_) {}
  // The shared waiter: a copy spawned while this one runs is handed to this
  // window and exits, and it would drop --portable.
  await relaunchApp();
}

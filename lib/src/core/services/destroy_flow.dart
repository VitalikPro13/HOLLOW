import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Local clean-up that follows a wipe, before the app relaunches to Welcome.
///
/// The relay holds a push token per device, so a wiped device would keep being
/// woken for messages it can no longer read. Both steps are best effort and the
/// unregister is bounded, because the node may already be down (the duress path
/// wipes before the node ever starts).
Future<void> clearLocalSecretsAfterDestroy() async {
  try {
    await AppLockService().clearAll();
  } catch (e) {
    debugPrint('[HOLLOW] destroy: app lock clear failed: $e');
  }
  try {
    await network_api
        .unregisterPushToken()
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint('[HOLLOW] destroy: push unregister skipped: $e');
  }
}

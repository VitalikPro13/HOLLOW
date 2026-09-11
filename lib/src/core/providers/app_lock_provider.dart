import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';

/// Desktop app lock: the UI is covered while the node keeps running. Unlocking
/// goes through the prompt a launch uses, which is what lets a duress code
/// typed here act with the keys already in memory.

/// The "Lock after" choices, in minutes. 0 is off.
const List<int> kLockAfterChoices = <int>[0, 5, 15, 60];

const String _kLockAfterKey = 'desktop_lock_after_minutes';

/// A phone re-locks when it comes back after this long in the background. Short
/// enough to matter, long enough that a file picker round trip does not lock.
const Duration kRelockAfterBackground = Duration(seconds: 15);

/// When the user last touched the app. A plain field and never provider state:
/// a mouse move must not rebuild anything.
class IdleClock {
  IdleClock._();

  static DateTime last = DateTime.now();

  static void stamp() => last = DateTime.now();
}

/// Whether enough idle time has passed to lock. Pure, so the rule is testable
/// without a clock or a widget tree.
bool shouldAutoLock({
  required int lockAfterMinutes,
  required DateTime lastInput,
  required DateTime now,
  required bool busy,
  required bool locked,
}) {
  if (lockAfterMinutes <= 0 || busy || locked) return false;
  return !now.isBefore(lastInput.add(Duration(minutes: lockAfterMinutes)));
}

/// Why the lock cannot go up, in the words the user is shown, or null when
/// nothing is in the way. The cover would hide the controls that end these.
final appLockBusyProvider = Provider<String?>((ref) {
  final call = ref.watch(callProvider);
  final vc = ref.watch(voiceChannelProvider);
  if (call.status != CallStatus.idle ||
      call.isScreenSharing ||
      vc.isInVoiceChannel ||
      vc.isScreenSharing) {
    return 'Finish the call first.';
  }
  if (downloadingShares(ref.watch(shareTabProvider)).isNotEmpty) {
    return 'Wait for the transfer to finish.';
  }
  return null;
});

/// Minutes of inactivity before the desktop UI locks. 0 = off. Loaded from
/// `HollowShell._bootstrap`, never an `AsyncNotifier` reading in `build()`:
/// `load_setting` throws until the store is open (#58).
final lockAfterMinutesProvider =
    NotifierProvider<LockAfterMinutesNotifier, int>(
        LockAfterMinutesNotifier.new);

class LockAfterMinutesNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Restore the persisted span. Call from `_bootstrap()` after the store opens.
  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: _kLockAfterKey);
      final parsed = int.tryParse(raw ?? '');
      if (parsed != null && kLockAfterChoices.contains(parsed)) state = parsed;
    } catch (e) {
      debugPrint('[HOLLOW] lockAfterMinutes.load() failed: $e');
    }
  }

  Future<void> setMinutes(int minutes) async {
    state = minutes;
    await storage_api.saveSetting(key: _kLockAfterKey, value: '$minutes');
  }
}

/// True while the lock cover is up.
final appLockedProvider =
    NotifierProvider<AppLockedNotifier, bool>(AppLockedNotifier.new);

class AppLockedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setLocked(bool locked) {
    state = locked;
    HollowToast.lockedOut = locked;
    if (!locked) return;
    // Raw overlay entries paint ABOVE every route, the cover included, so an
    // open picker or a toast raised a moment ago has to go first.
    HollowToast.dismissCurrent();
    OverlayHosts.dismissAll();
  }
}

/// True while the Argon2id derivation behind an unlock attempt is running. The
/// shell's own spinner sits under the cover, so the cover shows this one.
final appUnlockBusyProvider = StateProvider<bool>((ref) => false);

/// Raises the lock, or says why it cannot. The one place that refuses to lock
/// an identity with no password to lift the lock again.
void requestAppLock(WidgetRef ref, BuildContext context) {
  if (ref.read(appLockedProvider)) return;
  final hasPassword =
      ref.read(identityProtectionProvider).valueOrNull?.hasPassword ?? false;
  if (!hasPassword) return;
  final busy = ref.read(appLockBusyProvider);
  if (busy != null) {
    HollowToast.show(context, busy, type: HollowToastType.info);
    return;
  }
  ref.read(appLockedProvider.notifier).setLocked(true);
}

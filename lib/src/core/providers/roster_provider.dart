import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;

/// What our own roster says about THIS device, for the full-screen lock (design
/// ID-1): a member uses the app; a removed device waits for its erase or the
/// recovery phrase; a device restored from a backup, or one a recovery left
/// out, waits to be let in; a phrase restore the roster outdated before it
/// counted (HOL-SEC-218) types the phrase again.
enum RosterGateKind { none, removed, pending, tooEarly }

@immutable
class RosterGate {
  final RosterGateKind kind;

  /// The device that removed this one.
  final String? removedBy;

  /// When a removed device erases itself.
  final DateTime? wipeAt;

  /// When a waiting device joins on its own if nobody refuses it.
  final DateTime? joinsAt;

  /// A waiting device a phrase recovery on another device left out, since then.
  final DateTime? droppedAt;

  /// [RosterGateKind.tooEarly]: which statement came too early, so typing the
  /// phrase again makes the same one.
  final PhraseRestoreBranch? tooEarly;

  /// The moment a too-early recovery judged lost devices from, kept so the
  /// next one judges from it too.
  final int? lostSinceMs;

  const RosterGate({
    this.kind = RosterGateKind.none,
    this.removedBy,
    this.wipeAt,
    this.joinsAt,
    this.droppedAt,
    this.tooEarly,
    this.lostSinceMs,
  });

  static DateTime? _at(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);

  /// The gate a stored roster implies. An identity with no roster yet is none;
  /// any other device the roster does not count waits, with a date only while the
  /// phrase lets backups join by waiting.
  factory RosterGate.fromStatus(roster_api.RosterStatus s) =>
      RosterGate.from(
        member: s.member,
        anyDevice: s.devices.isNotEmpty,
        removedBy: s.removedBy,
        wipeAtMs: s.wipeAtMs,
        joinsAtMs: s.joinsAtMs,
        tooEarly: s.tooEarly,
        tooEarlyLostSinceMs: s.tooEarlyLostSinceMs,
        droppedByRecoveryAtMs: s.droppedByRecoveryAtMs,
      );

  /// [RosterGate.fromStatus] from its parts.
  factory RosterGate.from({
    required bool member,
    required bool anyDevice,
    String? removedBy,
    int? wipeAtMs,
    int? joinsAtMs,
    String? tooEarly,
    int? tooEarlyLostSinceMs,
    int? droppedByRecoveryAtMs,
  }) {
    if (member || !anyDevice) return const RosterGate();
    if (removedBy != null) {
      return RosterGate(
        kind: RosterGateKind.removed,
        removedBy: removedBy,
        wipeAt: _at(wipeAtMs),
      );
    }
    final early = tooEarly == null ? null : phraseRestoreBranchFrom(tooEarly);
    if (early != null) {
      return RosterGate(
        kind: RosterGateKind.tooEarly,
        tooEarly: early,
        lostSinceMs: tooEarlyLostSinceMs,
      );
    }
    return RosterGate(
      kind: RosterGateKind.pending,
      joinsAt: _at(joinsAtMs),
      droppedAt: _at(droppedByRecoveryAtMs),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RosterGate &&
      other.kind == kind &&
      other.removedBy == removedBy &&
      other.wipeAt == wipeAt &&
      other.joinsAt == joinsAt &&
      other.droppedAt == droppedAt &&
      other.tooEarly == tooEarly &&
      other.lostSinceMs == lostSinceMs;

  @override
  int get hashCode => Object.hash(
      kind, removedBy, wipeAt, joinsAt, droppedAt, tooEarly, lostSinceMs);
}

class RosterGateNotifier extends Notifier<RosterGate> {
  @override
  RosterGate build() => const RosterGate();

  /// Re-read the gate from the stored roster. Call once the node has started,
  /// which is when our own roster is brought up to date.
  Future<void> refresh() async {
    try {
      state = RosterGate.fromStatus(await roster_api.rosterStatus());
    } catch (e) {
      debugPrint('[HOLLOW] Roster status unavailable: $e');
    }
  }

  void removed(String by, int wipeAtMs) => state = RosterGate(
        kind: RosterGateKind.removed,
        removedBy: by,
        wipeAt: DateTime.fromMillisecondsSinceEpoch(wipeAtMs),
      );

  void restored() => state = const RosterGate();
}

final rosterGateProvider =
    NotifierProvider<RosterGateNotifier, RosterGate>(RosterGateNotifier.new);

/// Every device of ours and where it stands, for the Devices page. Invalidated
/// on every roster change.
final rosterStatusProvider = FutureProvider.autoDispose<roster_api.RosterStatus>(
  (ref) => roster_api.rosterStatus(),
);

/// An identity from before the phrase became its root still keeps the phrase it
/// stored then, until the person confirms it once (design ID-1).
final phraseUpgradePendingProvider = FutureProvider.autoDispose<bool>((ref) async {
  try {
    return await roster_api.storedPhraseForUpgrade() != null;
  } catch (_) {
    return false;
  }
});

/// Devices restored from a backup that asked to join while this app ran, oldest
/// first, waiting for this device's answer.
class PendingDeviceAsksNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void add(String device) {
    if (state.contains(device)) return;
    state = [...state, device];
  }

  void answered(String device) =>
      state = state.where((d) => d != device).toList();
}

final pendingDeviceAsksProvider =
    NotifierProvider<PendingDeviceAsksNotifier, List<String>>(
  PendingDeviceAsksNotifier.new,
);

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;

/// What our own roster says about THIS device, for the full-screen lock (design
/// ID-1): a member uses the app; a removed device waits for its erase or the
/// recovery phrase; a device restored from a backup waits to be let in.
enum RosterGateKind { none, removed, pending }

@immutable
class RosterGate {
  final RosterGateKind kind;

  /// The device that removed this one.
  final String? removedBy;

  /// When a removed device erases itself.
  final DateTime? wipeAt;

  /// When a waiting device joins on its own if nobody refuses it.
  final DateTime? joinsAt;

  const RosterGate({
    this.kind = RosterGateKind.none,
    this.removedBy,
    this.wipeAt,
    this.joinsAt,
  });

  static DateTime? _at(int? ms) =>
      ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);

  /// The gate a stored roster implies. An identity with no roster yet is none;
  /// any other device the roster does not count waits, with a date only while the
  /// phrase lets backups join by waiting.
  factory RosterGate.fromStatus(roster_api.RosterStatus s) {
    if (s.member || s.devices.isEmpty) return const RosterGate();
    if (s.removedBy != null) {
      return RosterGate(
        kind: RosterGateKind.removed,
        removedBy: s.removedBy,
        wipeAt: _at(s.wipeAtMs),
      );
    }
    return RosterGate(kind: RosterGateKind.pending, joinsAt: _at(s.joinsAtMs));
  }

  @override
  bool operator ==(Object other) =>
      other is RosterGate &&
      other.kind == kind &&
      other.removedBy == removedBy &&
      other.wipeAt == wipeAt &&
      other.joinsAt == joinsAt;

  @override
  int get hashCode => Object.hash(kind, removedBy, wipeAt, joinsAt);
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

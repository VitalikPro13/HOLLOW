import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/verification.dart' as verification_api;

/// Alert kinds, mirroring `node::security_alerts::KIND_*` in Rust.
///
/// Dual-defined on purpose (same pattern as the emote wire token): the wire
/// strings are part of the persisted DB, so both sides must agree. If you add a
/// kind, add it in BOTH places.
abstract final class SecurityAlertKind {
  /// A device joined this contact's master-signed device list. This is the one
  /// that carries an attack signal — it is the shape of "someone linked a
  /// device to an account they compromised".
  static const newDevice = 'new_device';

  /// One of this contact's devices presented a new Olm identity key — they
  /// reinstalled or re-keyed. Informational: since 0.8.2 key exchange is
  /// authenticated, so a changed key is no longer evidence of an attack.
  static const identityKeyChanged = 'identity_key_changed';
}

/// Security alerts recorded for contacts (Issue 1-C).
///
/// Holds the FULL history, read and dismissed alike — dismissing is not
/// deleting. The conversation banner filters to unacknowledged; the record
/// survives so "when did a device appear for this person" stays answerable.
class SecurityAlertsNotifier extends Notifier<List<verification_api.SecurityAlertFfi>> {
  @override
  List<verification_api.SecurityAlertFfi> build() => const [];

  /// Load from the database. Called once at shell startup.
  Future<void> load() async {
    try {
      state = await verification_api.getSecurityAlerts();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load security alerts: $e');
    }
  }

  /// Re-pull after a live `SecurityAlert` event. Rust has already persisted and
  /// deduped by then, so reloading is the simplest way to stay in step with the
  /// DB rather than maintaining a parallel insert path that could drift.
  Future<void> refresh() => load();

  /// Dismiss every outstanding alert for one contact (the banner's Dismiss).
  /// Rethrows so the call site can report failure — a Dismiss that silently
  /// does nothing would have the user believe they cleared a warning.
  Future<void> acknowledgeForPeer(String peerId) async {
    final master = ref.read(deviceLinkProvider).identityOf(peerId);
    await verification_api.acknowledgeSecurityAlertsForPeer(peerId: master);
    await load();
  }
}

final securityAlertsProvider = NotifierProvider<SecurityAlertsNotifier,
    List<verification_api.SecurityAlertFfi>>(SecurityAlertsNotifier.new);

/// Unacknowledged alerts for one contact, newest first. Accepts a device OR
/// master id.
final peerSecurityAlertsProvider =
    Provider.family<List<verification_api.SecurityAlertFfi>, String>(
        (ref, peerId) {
  final master = ref.watch(deviceLinkProvider).identityOf(peerId);
  return ref
      .watch(securityAlertsProvider)
      .where((a) => a.peerId == master && a.acknowledgedAt == null)
      .toList();
});

/// Master ids with at least one outstanding alert — for badging conversation
/// rows in the DM list, so the warning is visible before the chat is opened.
final peersWithSecurityAlertsProvider = Provider<Set<String>>((ref) {
  return ref
      .watch(securityAlertsProvider)
      .where((a) => a.acknowledgedAt == null)
      .map((a) => a.peerId)
      .toSet();
});

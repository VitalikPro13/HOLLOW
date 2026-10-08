import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/verification.dart' as verification_api;

/// Alert kinds, mirroring `node::security_alerts::KIND_*` in Rust.
///
/// Dual-defined on purpose: the wire strings are part of the persisted DB, so
/// both sides must agree. Adding a kind means adding it in BOTH places.
abstract final class SecurityAlertKind {
  /// A device joined this contact's master-signed device list. The one kind that
  /// carries an attack signal: someone linking a device to a compromised account.
  static const newDevice = 'new_device';

  /// One of this contact's devices presented a new Olm identity key. Informational:
  /// key exchange is authenticated, so a changed key is not evidence of an attack.
  static const identityKeyChanged = 'identity_key_changed';

  /// This contact announced their identity destroyed and it is signing again.
  /// The recovery phrase can rebuild the same keys, so this is not proof of an
  /// impostor, and it is the strongest reason to check a safety number.
  static const identityReappeared = 'identity_reappeared';

  /// Another of OUR devices added a device to our identity (C-IDENTITY-09). Filed
  /// under our own master, so it is never a contact's alert.
  static const ownDeviceAdded = 'own_device_added';
}

/// What an own-device alert names: the device added and the device of ours that
/// added it.
({String device, String by})? ownDeviceAddedDetail(
    verification_api.SecurityAlertFfi alert) {
  if (alert.kind != SecurityAlertKind.ownDeviceAdded) return null;
  final parts = alert.detail.split(':');
  if (parts.length != 2 || parts.any((p) => p.isEmpty)) return null;
  return (device: parts[0], by: parts[1]);
}

/// Security alerts recorded for contacts (Issue 1-C).
///
/// The FULL history, read and dismissed alike: dismissing is not deleting, so
/// "when did a device appear for this person" stays answerable.
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
  /// deduped, so reloading avoids a parallel insert path that could drift.
  Future<void> refresh() => load();

  /// Dismiss every outstanding alert for one contact (the banner's Dismiss).
  /// Rethrows so the call site can report failure — a Dismiss that silently
  /// does nothing would have the user believe they cleared a warning.
  Future<void> acknowledgeForPeer(String peerId) async {
    final master = ref.read(deviceLinkProvider).identityOf(peerId);
    await verification_api.acknowledgeSecurityAlertsForPeer(peerId: master);
    await load();
  }

  /// Dismiss one alert. Rethrows, as [acknowledgeForPeer] does.
  Future<void> acknowledge(String alertId) async {
    await verification_api.acknowledgeSecurityAlert(alertId: alertId);
    await load();
  }
}

/// Outstanding alerts about a CONTACT; our own identity's are not a contact's.
Iterable<verification_api.SecurityAlertFfi> _outstandingContactAlerts(
        List<verification_api.SecurityAlertFfi> alerts) =>
    alerts.where((a) =>
        a.acknowledgedAt == null && a.kind != SecurityAlertKind.ownDeviceAdded);

final securityAlertsProvider = NotifierProvider<SecurityAlertsNotifier,
    List<verification_api.SecurityAlertFfi>>(SecurityAlertsNotifier.new);

/// Unacknowledged alerts for one contact, newest first. Accepts a device OR
/// master id.
final peerSecurityAlertsProvider =
    Provider.family<List<verification_api.SecurityAlertFfi>, String>(
        (ref, peerId) {
  final master = ref.watch(deviceLinkProvider).identityOf(peerId);
  return _outstandingContactAlerts(ref.watch(securityAlertsProvider))
      .where((a) => a.peerId == master)
      .toList();
});

/// Master ids with at least one outstanding alert — for badging conversation
/// rows in the DM list, so the warning is visible before the chat is opened.
final peersWithSecurityAlertsProvider = Provider<Set<String>>((ref) {
  return _outstandingContactAlerts(ref.watch(securityAlertsProvider))
      .map((a) => a.peerId)
      .toSet();
});

/// Outstanding alerts that another of our devices added one, newest first.
final ownDeviceAlertsProvider =
    Provider<List<verification_api.SecurityAlertFfi>>((ref) {
  return ref
      .watch(securityAlertsProvider)
      .where((a) =>
          a.acknowledgedAt == null &&
          a.kind == SecurityAlertKind.ownDeviceAdded)
      .toList();
});

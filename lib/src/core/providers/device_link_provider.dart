import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Device → master identity map for the UI attribution layer (multi-device,
/// Phase 6).
///
/// The Rust node owns the authoritative resolver (learned from verified, signed
/// device lists). This provider mirrors it into Dart so the UI can synchronously
/// collapse a friend's several device peer_ids into the one person — without an
/// async FFI hop per message bubble / member row. It is refreshed whenever a
/// `DeviceListUpdated` event fires (see `event_provider`).
///
/// On a single-device install the map is empty (or only self-mappings), so
/// `identityOf()` returns the input unchanged — i.e. a perfect no-op. Never gate
/// rendering on this: an unknown peer always resolves to itself.
class DeviceLinkState {
  /// device_peer_id → master_peer_id.
  final Map<String, String> links;

  const DeviceLinkState({this.links = const {}});

  /// Resolve a (possibly per-device) peer_id to its master identity. Unknown
  /// peers resolve to themselves (backward compatible).
  String identityOf(String peerId) => links[peerId] ?? peerId;

  /// True iff two peer_ids belong to the same person (master identity).
  bool sameIdentity(String a, String b) =>
      a == b || identityOf(a) == identityOf(b);
}

class DeviceLinkNotifier extends Notifier<DeviceLinkState> {
  @override
  DeviceLinkState build() => const DeviceLinkState();

  /// Pull the current (device → master) links from the running node's resolver.
  /// Cheap (in-memory snapshot on the Rust side); safe to call on every
  /// `DeviceListUpdated`.
  Future<void> refresh() async {
    try {
      final rows = await network_api.getDeviceLinks();
      final newLinks = {
        for (final l in rows) l.devicePeerId: l.masterPeerId,
      };
      // Unchanged-map guard: DeviceListUpdated fires often; a fresh-but-equal
      // state object used to fan a rebuild to every watch site anyway.
      if (mapEquals(newLinks, state.links)) return;
      state = DeviceLinkState(links: newLinks);
    } catch (e) {
      // Node not started yet, or transient FFI error — keep the old map.
      debugPrint('[HOLLOW] Device link refresh failed: $e');
    }
  }
}

final deviceLinkProvider =
    NotifierProvider<DeviceLinkNotifier, DeviceLinkState>(
  DeviceLinkNotifier.new,
);

/// The set of **master identities** that have at least one visible device
/// online (multi-device, Phase 6).
///
/// Presence (`peersProvider`) and invisibility (`invisiblePeersProvider`) are
/// keyed by the **device** peer_id the relay actually reports. Friend / DM /
/// profile UI, however, keys on the **master** identity (a friendship is with a
/// person, not a device). This provider bridges the two: it folds every visible
/// online device into its master identity, so a friend connected via *any* of
/// their devices shows as one online person.
///
/// Mirrors the Rust resolver's `peer_is_reachable` ("a master is reachable if
/// any of its devices is in a room"). On a single-device install the resolver is
/// the identity map (device == master), so this collapses to exactly the old
/// `peers.keys - invisible` set — a perfect no-op.
///
/// Use [identityIsOnline] rather than the raw `peers.containsKey(id)` for any
/// friend/DM/profile online check.
final onlineIdentitiesProvider =
    NotifierProvider<OnlineIdentitiesNotifier, Set<String>>(
        OnlineIdentitiesNotifier.new);

/// Notifier (not a plain Provider) purely for [updateShouldNotify]: the
/// recompute mints a fresh Set every time a peer event fires, and identity
/// `==` meant ~20 always-mounted watchers rebuilt per event even when the
/// online set hadn't actually changed (e.g. markEncrypted).
class OnlineIdentitiesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    final peers = ref.watch(peersProvider);
    final invisible = ref.watch(invisiblePeersProvider);
    final links = ref.watch(deviceLinkProvider);

    final online = <String>{};
    for (final devicePeerId in peers.keys) {
      if (invisible.contains(devicePeerId)) continue;
      online.add(links.identityOf(devicePeerId));
    }
    return online;
  }

  @override
  bool updateShouldNotify(Set<String> previous, Set<String> next) =>
      !setEquals(previous, next);
}

/// True iff the friend/identity behind [masterPeerId] is online on any visible
/// device. Pass the friend's stored peer_id (a master identity); single-device
/// peers resolve to themselves, so this is correct in both worlds.
bool identityIsOnline(WidgetRef ref, String masterPeerId) =>
    ref.watch(onlineIdentitiesProvider).contains(masterPeerId);

// ── Step 8: Devices panel ──────────────────────────────────────────────

/// The transport peer_id of the device this app is RUNNING on (distinct from the
/// master identity in `get_local_peer_id`). Used to mark "This device" + hide its
/// Remove button. `null` until the node has loaded an identity.
final localDevicePeerIdProvider = FutureProvider<String?>((ref) async {
  try {
    return await network_api.getLocalDevicePeerId();
  } catch (_) {
    return null;
  }
});

/// Local human labels for devices (Step 8). device_peer_id → label. Refreshed on
/// `DeviceListUpdated`, same as [deviceLinkProvider].
class DeviceLabelNotifier extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};

  Future<void> refresh() async {
    try {
      final rows = await network_api.getDeviceLabels();
      state = {for (final l in rows) l.devicePeerId: l.label};
    } catch (e) {
      debugPrint('[HOLLOW] Device label refresh failed: $e');
    }
  }

  /// Optimistically set the label, then persist (fire-and-forget — the local
  /// table write is cheap but we don't block the UI on it).
  Future<void> setLabel(String devicePeerId, String label) async {
    state = {...state}..[devicePeerId] = label;
    try {
      await network_api.setDeviceLabel(devicePeerId: devicePeerId, label: label);
    } catch (e) {
      debugPrint('[HOLLOW] setDeviceLabel failed: $e');
    }
  }
}

final deviceLabelProvider =
    NotifierProvider<DeviceLabelNotifier, Map<String, String>>(
  DeviceLabelNotifier.new,
);

/// One of MY OWN devices, for the Devices panel.
class MyDevice {
  final String peerId;
  final bool isThisDevice;
  final bool online;
  final String label;

  const MyDevice({
    required this.peerId,
    required this.isThisDevice,
    required this.online,
    required this.label,
  });
}

/// My own devices (every device peer_id that resolves to MY master), with live
/// online status + local label. Empty / single-entry on a single-device install.
///
/// Sourced from the resolver mirror (`deviceLinkProvider.links`) inverted against
/// my master id: `seed_self` puts my own devices in that map. The running device
/// is always included even if the resolver hasn't folded it in yet.
final myDevicesProvider = Provider<List<MyDevice>>((ref) {
  final links = ref.watch(deviceLinkProvider);
  final labels = ref.watch(deviceLabelProvider);
  final peers = ref.watch(peersProvider);
  final invisible = ref.watch(invisiblePeersProvider);
  final myDeviceId = ref.watch(localDevicePeerIdProvider).valueOrNull;

  // My master = what my own device resolves to. Falls back to the device id
  // itself (single-device / keystone install → device == master).
  final myMaster = myDeviceId == null ? null : links.identityOf(myDeviceId);

  final ids = <String>{};
  if (myMaster != null) {
    // Every device whose master is mine (excludes the bare master, which is not a
    // real device — it never appears as a transport peer).
    for (final entry in links.links.entries) {
      if (entry.value == myMaster && entry.key != myMaster) ids.add(entry.key);
    }
  }
  if (myDeviceId != null) ids.add(myDeviceId); // always list the running device

  final list = ids.map((id) {
    final isThis = id == myDeviceId;
    // The running device is online by definition; others via presence maps.
    final online = isThis ||
        (peers.containsKey(id) && !invisible.contains(id));
    return MyDevice(
      peerId: id,
      isThisDevice: isThis,
      online: online,
      label: labels[id] ?? '',
    );
  }).toList()
    // This device first, then online, then by id for stability.
    ..sort((a, b) {
      if (a.isThisDevice != b.isThisDevice) return a.isThisDevice ? -1 : 1;
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.peerId.compareTo(b.peerId);
    });
  return list;
});

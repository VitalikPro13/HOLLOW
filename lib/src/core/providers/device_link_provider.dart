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
      if (rows.isEmpty && state.links.isEmpty) return; // nothing to change
      state = DeviceLinkState(
        links: {
          for (final l in rows) l.devicePeerId: l.masterPeerId,
        },
      );
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
final onlineIdentitiesProvider = Provider<Set<String>>((ref) {
  final peers = ref.watch(peersProvider);
  final invisible = ref.watch(invisiblePeersProvider);
  final links = ref.watch(deviceLinkProvider);

  final online = <String>{};
  for (final devicePeerId in peers.keys) {
    if (invisible.contains(devicePeerId)) continue;
    online.add(links.identityOf(devicePeerId));
  }
  return online;
});

/// True iff the friend/identity behind [masterPeerId] is online on any visible
/// device. Pass the friend's stored peer_id (a master identity); single-device
/// peers resolve to themselves, so this is correct in both worlds.
bool identityIsOnline(WidgetRef ref, String masterPeerId) =>
    ref.watch(onlineIdentitiesProvider).contains(masterPeerId);

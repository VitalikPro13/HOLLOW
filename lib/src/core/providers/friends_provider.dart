import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/services/push_hints_cache.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// A friend entry from the local DB.
class FriendInfo {
  final String peerId;
  final String status; // 'pending', 'accepted'
  final String direction; // 'outgoing', 'incoming', '' (accepted)
  final int requestedAt;
  final int updatedAt;

  const FriendInfo({
    required this.peerId,
    required this.status,
    required this.direction,
    required this.requestedAt,
    required this.updatedAt,
  });
}

/// Manages the friends list. Loaded from local DB.
class FriendsNotifier extends Notifier<Map<String, FriendInfo>> {
  @override
  Map<String, FriendInfo> build() => {};

  Future<void> loadAll() async {
    try {
      final rows = await storage_api.loadFriends();
      final map = <String, FriendInfo>{};
      for (final f in rows) {
        map[f.peerId] = FriendInfo(
          peerId: f.peerId,
          status: f.status,
          direction: f.direction,
          requestedAt: f.requestedAt,
          updatedAt: f.updatedAt,
        );
      }
      state = map;
      // Refresh the iOS push-hints cache. Debounced + iOS-gated internally, and
      // covers every friend mutation since they all funnel through loadAll().
      PushHintsCache.scheduleWrite(map.keys);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load friends: $e');
    }
  }

  // The four mutations below RETHROW (like profile_provider.updateMyProfile)
  // so call sites can toast the failure — a swallow here made every caller's
  // "sent/accepted" feedback lie on a dead node.

  /// Send a friend request.
  Future<void> sendRequest(String peerId) async {
    try {
      await network_api.sendFriendRequest(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to send friend request: $e');
      rethrow;
    }
  }

  /// Accept an incoming friend request.
  Future<void> acceptRequest(String peerId) async {
    try {
      await network_api.acceptFriendRequest(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to accept friend request: $e');
      rethrow;
    }
  }

  /// Reject an incoming friend request.
  Future<void> rejectRequest(String peerId) async {
    try {
      await network_api.rejectFriendRequest(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to reject friend request: $e');
      rethrow;
    }
  }

  /// Remove a friend.
  Future<void> removeFriend(String peerId) async {
    try {
      await network_api.removeFriend(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to remove friend: $e');
      rethrow;
    }
  }
}

final friendsProvider =
    NotifierProvider<FriendsNotifier, Map<String, FriendInfo>>(
        FriendsNotifier.new);

/// ALL accepted friends, master-collapsed + deduped, sorted by online status
/// then display name.
///
/// The canonical accepted-friends list for every "show me my friends" surface.
/// It does NOT apply the favourites filter, which belongs ONLY to the
/// horizontal FriendsBar dock: mixing the two made favouriting one friend hide
/// every other friend from the dialog, home and chats.
final sortedFriendsProvider = Provider<List<FriendInfo>>((ref) {
  final friends = ref.watch(friendsProvider);
  // Multi-device: collapse a friend's device peer_ids into one master identity
  // for online status. Single-device installs resolve each peer to itself.
  final online = ref.watch(onlineIdentitiesProvider);
  final profiles = ref.watch(profileProvider);
  // A friend row added by TEMPORARY NICKNAME is keyed under the friend's DEVICE
  // id (the relay claims nicknames under the device socket) while presence keys
  // on the MASTER, so resolve device->master before the backend re-key lands.
  final links = ref.watch(deviceLinkProvider);

  // Collapse each accepted friend's stored id to its MASTER and dedupe, so every
  // render site keys its online dot, name and avatar correctly. A friend stranded
  // under a device id heals here as soon as `deviceLinkProvider` knows the map.
  final byMaster = <String, FriendInfo>{};
  for (final f in friends.values.where((f) => f.status == 'accepted')) {
    final master = links.identityOf(f.peerId);
    final resolved = master == f.peerId
        ? f
        : FriendInfo(
            peerId: master,
            status: f.status,
            direction: f.direction,
            requestedAt: f.requestedAt,
            updatedAt: f.updatedAt,
          );
    // Keep the most-recently-updated row if two device rows collapse to one.
    final existing = byMaster[master];
    if (existing == null || resolved.updatedAt >= existing.updatedAt) {
      byMaster[master] = resolved;
    }
  }
  final accepted = byMaster.values.toList();
  accepted.sort((a, b) {
    final aOnline = online.contains(a.peerId) ? 0 : 1;
    final bOnline = online.contains(b.peerId) ? 0 : 1;
    if (aOnline != bOnline) return aOnline.compareTo(bOnline);
    final aName = displayNameFor(profiles, a.peerId);
    final bName = displayNameFor(profiles, b.peerId);
    return aName.compareTo(bName);
  });

  return accepted;
});

/// The friend list to render in the horizontal FriendsBar DOCK only.
///
/// With favourites set the dock shows ONLY those, in their drag order;
/// otherwise all accepted friends. Favourite ids are resolved device->master
/// before matching, so a favourite saved under a device id still matches.
///
/// IMPORTANT: only the dock reads this. Every other surface reads
/// [sortedFriendsProvider], so favouriting can never hide a friend from them.
final friendsBarDisplayProvider = Provider<List<FriendInfo>>((ref) {
  final accepted = ref.watch(sortedFriendsProvider);
  final favourites = ref.watch(favouriteFriendsProvider);
  if (favourites.isEmpty) return accepted;

  final links = ref.watch(deviceLinkProvider);
  // Index accepted friends by master so a favourite id (possibly a stale device
  // id) resolves to the right friend.
  final byMaster = {for (final f in accepted) f.peerId: f};
  final out = <FriendInfo>[];
  final seen = <String>{};
  for (final favId in favourites) {
    final master = links.identityOf(favId);
    final friend = byMaster[master];
    if (friend != null && seen.add(master)) out.add(friend);
  }
  return out;
});

/// Count of incoming pending friend requests (for badge display).
final pendingFriendCountProvider = Provider<int>((ref) {
  final friends = ref.watch(friendsProvider);
  return friends.values
      .where((f) => f.status == 'pending' && f.direction == 'incoming')
      .length;
});

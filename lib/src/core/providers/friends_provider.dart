import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
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

  /// Load all friends from DB.
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
      // Refresh the iOS push-hints cache (friend name + avatar for the
      // Notification Service Extension). Debounced + iOS-gated internally, so
      // this is a cheap no-op on other platforms. Covers startup + every friend
      // mutation since they all funnel through loadAll().
      PushHintsCache.scheduleWrite(map.keys);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load friends: $e');
    }
  }

  /// Send a friend request.
  Future<void> sendRequest(String peerId) async {
    try {
      await network_api.sendFriendRequest(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to send friend request: $e');
    }
  }

  /// Accept an incoming friend request.
  Future<void> acceptRequest(String peerId) async {
    try {
      await network_api.acceptFriendRequest(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to accept friend request: $e');
    }
  }

  /// Reject an incoming friend request.
  Future<void> rejectRequest(String peerId) async {
    try {
      await network_api.rejectFriendRequest(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to reject friend request: $e');
    }
  }

  /// Remove a friend.
  Future<void> removeFriend(String peerId) async {
    try {
      await network_api.removeFriend(peerId: peerId);
      await loadAll();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to remove friend: $e');
    }
  }
}

final friendsProvider =
    NotifierProvider<FriendsNotifier, Map<String, FriendInfo>>(
        FriendsNotifier.new);

/// Accepted friends sorted by online status (online first) then alphabetical
/// display name, with favourites override applied when favourites exist.
/// Memoized — only recomputes when the upstream providers change.
final sortedFriendsProvider = Provider<List<FriendInfo>>((ref) {
  final friends = ref.watch(friendsProvider);
  final peers = ref.watch(peersProvider);
  final invisiblePeers = ref.watch(invisiblePeersProvider);
  final profiles = ref.watch(profileProvider);
  final favourites = ref.watch(favouriteFriendsProvider);

  final accepted = friends.values
      .where((f) => f.status == 'accepted')
      .toList();
  accepted.sort((a, b) {
    final aOnline =
        (peers.containsKey(a.peerId) && !invisiblePeers.contains(a.peerId))
            ? 0
            : 1;
    final bOnline =
        (peers.containsKey(b.peerId) && !invisiblePeers.contains(b.peerId))
            ? 0
            : 1;
    if (aOnline != bOnline) return aOnline.compareTo(bOnline);
    final aName = displayNameFor(profiles, a.peerId);
    final bName = displayNameFor(profiles, b.peerId);
    return aName.compareTo(bName);
  });

  // When favourites exist, show only favourites in their custom order.
  // Filter out any stale favourites (removed friends).
  if (favourites.isNotEmpty) {
    final acceptedIds = accepted.map((f) => f.peerId).toSet();
    return favourites
        .where((id) => acceptedIds.contains(id))
        .map((id) => accepted.firstWhere((f) => f.peerId == id))
        .toList();
  }

  return accepted;
});

/// Count of incoming pending friend requests (for badge display).
final pendingFriendCountProvider = Provider<int>((ref) {
  final friends = ref.watch(friendsProvider);
  return friends.values
      .where((f) => f.status == 'pending' && f.direction == 'incoming')
      .length;
});

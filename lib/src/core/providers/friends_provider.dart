import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
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

/// Whether a list has been read from this device yet, and why the first read
/// failed. An empty list means "none" only once [loaded] is true.
typedef ListLoadState = ({bool loaded, Object? error});

/// [friendsProvider]'s load, kept apart so its many readers keep the map.
final friendsLoadStateProvider =
    StateProvider<ListLoadState>((_) => (loaded: false, error: null));

/// Manages the friends list. Loaded from local DB.
class FriendsNotifier extends Notifier<Map<String, FriendInfo>> {
  @override
  Map<String, FriendInfo> build() => {};

  Future<void> loadAll() async {
    final load = ref.read(friendsLoadStateProvider.notifier);
    // A retry reads as loading again, not as the failure it follows.
    if (load.state.error != null) load.state = (loaded: false, error: null);
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
      load.state = (loaded: true, error: null);
      // Refresh the iOS push-hints cache. Debounced + iOS-gated internally, and
      // covers every friend mutation since they all funnel through loadAll().
      PushHintsCache.scheduleWrite(map.keys);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load friends: $e');
      // A list already on screen stays; only one never read fails.
      if (!load.state.loaded) load.state = (loaded: false, error: e);
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
    return compareFriendNames(profiles, a.peerId, b.peerId);
  });

  return accepted;
});

/// Case-insensitive, so "alice" does not sort after "Zed"; the raw compare
/// breaks ties so the order is total and stable.
int compareFriendNames(
    Map<String, storage_api.UserProfile> profiles, String a, String b) {
  final an = displayNameFor(profiles, a);
  final bn = displayNameFor(profiles, b);
  final folded = an.toLowerCase().compareTo(bn.toLowerCase());
  if (folded != 0) return folded;
  final raw = an.compareTo(bn);
  return raw != 0 ? raw : a.compareTo(b);
}

/// What the header's friend strip shows, in its own stable order.
class FriendsBarContent {
  /// Favourites in their drag order, or every friend by name when none are set.
  final List<FriendInfo> leading;

  /// Non-favourites with unread messages: unread beats the filter.
  final List<FriendInfo> extras;

  /// Friends the favourites filter keeps off the strip.
  final int hidden;

  const FriendsBarContent({
    required this.leading,
    this.extras = const [],
    this.hidden = 0,
  });

  bool get isEmpty => leading.isEmpty && extras.isEmpty;
}

/// The header strip's friends. Only the strip reads this; every other surface
/// reads [sortedFriendsProvider], so favouriting never hides a friend there.
///
/// Sorted by name rather than online-first, so chips never jump when someone
/// connects. Favourite ids resolve device->master, and a list of ONLY stale
/// favourites behaves as no favourites.
final friendsBarProvider = Provider<FriendsBarContent>((ref) {
  final accepted = ref.watch(sortedFriendsProvider);
  final profiles = ref.watch(profileProvider);
  final byName = [...accepted]
    ..sort((a, b) => compareFriendNames(profiles, a.peerId, b.peerId));

  final links = ref.watch(deviceLinkProvider);
  final byMaster = {for (final f in accepted) f.peerId: f};
  final favourites = <FriendInfo>[];
  for (final favId in ref.watch(favouriteFriendsProvider)) {
    final friend = byMaster[links.identityOf(favId)];
    if (friend != null && !favourites.contains(friend)) favourites.add(friend);
  }
  if (favourites.isEmpty) return FriendsBarContent(leading: byName);

  final unread = ref.watch(unreadProvider.select((s) => s.dmUnreadCounts));
  final notif = ref.watch(notificationSettingsProvider);
  final extras = [
    for (final f in byName)
      if (!favourites.contains(f) &&
          notif.isDmEnabled(f.peerId) &&
          (unread[f.peerId] ?? 0) > 0)
        f,
  ];
  return FriendsBarContent(
    leading: favourites,
    extras: extras,
    hidden: byName.length - favourites.length - extras.length,
  );
});

/// Count of incoming pending friend requests (for badge display).
final pendingFriendCountProvider = Provider<int>((ref) {
  final friends = ref.watch(friendsProvider);
  return friends.values
      .where((f) => f.status == 'pending' && f.direction == 'incoming')
      .length;
});

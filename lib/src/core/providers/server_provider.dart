import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// Manages the list of servers the user has joined.
class ServerListNotifier extends Notifier<Map<String, ServerInfo>> {
  @override
  Map<String, ServerInfo> build() => {};

  /// Load servers from the local DB (called on startup).
  Future<void> loadFromDb() async {
    try {
      final servers = await crdt_api.getJoinedServers();
      final map = <String, ServerInfo>{};
      for (final s in servers) {
        map[s.serverId] = ServerInfo(
          serverId: s.serverId,
          name: s.name,
          memberCount: s.memberCount,
          channelCount: s.channelCount,
        );
      }
      state = map;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load servers: $e');
    }
  }

  /// Called when a ServerCreated event arrives.
  void onServerCreated(String serverId, String name) {
    final updated = Map.of(state);
    updated[serverId] = ServerInfo(
      serverId: serverId,
      name: name,
      memberCount: 1,
      channelCount: 1, // #general
    );
    state = updated;
  }

  /// Called when a ServerUpdated event arrives — full reload from DB.
  Future<void> onServerUpdated(String serverId) async {
    try {
      // Reload all servers to get fresh name + counts
      final servers = await crdt_api.getJoinedServers();
      final match = servers.where((s) => s.serverId == serverId).firstOrNull;
      final updated = Map.of(state);
      if (match != null) {
        updated[serverId] = ServerInfo(
          serverId: match.serverId,
          name: match.name,
          memberCount: match.memberCount,
          channelCount: match.channelCount,
        );
      } else {
        // Server no longer exists (user was kicked or server deleted while offline).
        updated.remove(serverId);
      }
      state = updated;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to refresh server $serverId: $e');
    }
  }

  /// Called when a ServerDeleted event arrives.
  void onServerDeleted(String serverId) {
    state = Map.of(state)..remove(serverId);
  }
}

final serverListProvider =
    NotifierProvider<ServerListNotifier, Map<String, ServerInfo>>(
        ServerListNotifier.new);

/// Currently selected server ID.
final selectedServerProvider = StateProvider<String?>((ref) => null);

/// Whether the server settings panel is open (replaces chat pane).
final serverSettingsOpenProvider = StateProvider<bool>((ref) => false);

/// Sync status for a server's message sync process.
enum ServerSyncStatus { idle, connecting, syncing, synced, retrying, failed }

/// Manages per-server sync status.
class SyncStatusNotifier extends Notifier<Map<String, ServerSyncStatus>> {
  @override
  Map<String, ServerSyncStatus> build() => {};

  void setStatus(String serverId, ServerSyncStatus status) {
    final updated = Map.of(state);
    updated[serverId] = status;
    state = updated;
  }
}

final syncStatusProvider =
    NotifierProvider<SyncStatusNotifier, Map<String, ServerSyncStatus>>(
        SyncStatusNotifier.new);

/// Convenience: read the sync status for a single server.
final serverSyncStatusProvider =
    Provider.family<ServerSyncStatus, String>((ref, serverId) {
  return ref.watch(syncStatusProvider)[serverId] ?? ServerSyncStatus.idle;
});

/// Fetches server members on demand. Invalidate to force refresh.
final serverMembersProvider =
    FutureProvider.family<List<crdt_api.MemberFfi>, String>(
  (ref, serverId) => crdt_api.getServerMembers(serverId: serverId),
);

/// Returns the set of online member peer IDs for a server.
final onlineMembersProvider =
    Provider.family<Set<String>, String>((ref, serverId) {
  final connectedPeers = ref.watch(peersProvider);
  final membersAsync = ref.watch(serverMembersProvider(serverId));
  return membersAsync.when(
    data: (members) => members
        .where((m) => connectedPeers.containsKey(m.peerId))
        .map((m) => m.peerId)
        .toSet(),
    loading: () => {},
    error: (_, _) => {},
  );
});

/// The local user's role in a server. Invalidated on RoleChanged events.
final myRoleProvider = FutureProvider.family<String, String>(
  (ref, serverId) => crdt_api.getMyRole(serverId: serverId),
);

/// The local user's permissions bitmask in a server.
final myPermissionsProvider = FutureProvider.family<int, String>(
  (ref, serverId) => crdt_api.getMyPermissions(serverId: serverId),
);

/// Extracts nicknames from server members: peerId → nickname (non-empty only).
final serverNicknamesProvider =
    Provider.family<Map<String, String>, String>((ref, serverId) {
  final membersAsync = ref.watch(serverMembersProvider(serverId));
  return membersAsync.when(
    data: (members) {
      final map = <String, String>{};
      for (final m in members) {
        if (m.nickname.isNotEmpty) {
          map[m.peerId] = m.nickname;
        }
      }
      return map;
    },
    loading: () => {},
    error: (_, _) => {},
  );
});

/// Permission bitmask constants (must match Rust Permission struct).
class Permission {
  static const int manageServer = 1 << 0;
  static const int manageChannels = 1 << 1;
  static const int manageRoles = 1 << 2;
  static const int manageInvites = 1 << 3;
  static const int kickMembers = 1 << 4;
  static const int sendMessages = 1 << 5;
  static const int readMessages = 1 << 6;
  static const int all = manageServer |
      manageChannels |
      manageRoles |
      manageInvites |
      kickMembers |
      sendMessages |
      readMessages;
}

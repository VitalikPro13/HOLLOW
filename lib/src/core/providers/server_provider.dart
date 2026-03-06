import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/server_info.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/rust/api/crdt.dart' as crdt_api;

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
      debugPrint('[HAVEN] Failed to load servers: $e');
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
      if (match != null) {
        final updated = Map.of(state);
        updated[serverId] = ServerInfo(
          serverId: match.serverId,
          name: match.name,
          memberCount: match.memberCount,
          channelCount: match.channelCount,
        );
        state = updated;
      }
    } catch (e) {
      debugPrint('[HAVEN] Failed to refresh server $serverId: $e');
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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/server_info.dart';
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
    state = {
      ...state,
      serverId: ServerInfo(
        serverId: serverId,
        name: name,
        memberCount: 1,
        channelCount: 1, // #general
      ),
    };
  }

  /// Called when a ServerUpdated event arrives — reload from DB.
  Future<void> onServerUpdated(String serverId) async {
    try {
      final channels = await crdt_api.getServerChannels(serverId: serverId);
      final members = await crdt_api.getServerMembers(serverId: serverId);
      final existing = state[serverId];
      if (existing != null) {
        state = {
          ...state,
          serverId: existing.copyWith(
            memberCount: members.length,
            channelCount: channels.length,
          ),
        };
      }
    } catch (e) {
      debugPrint('[HAVEN] Failed to refresh server $serverId: $e');
    }
  }

  /// Remove a server from the local list.
  void removeServer(String serverId) {
    state = Map.of(state)..remove(serverId);
  }
}

final serverListProvider =
    NotifierProvider<ServerListNotifier, Map<String, ServerInfo>>(
        ServerListNotifier.new);

/// Currently selected server ID.
final selectedServerProvider = StateProvider<String?>((ref) => null);

/// Fetches server members on demand. Invalidate to force refresh.
final serverMembersProvider =
    FutureProvider.family<List<crdt_api.MemberFfi>, String>(
  (ref, serverId) => crdt_api.getServerMembers(serverId: serverId),
);

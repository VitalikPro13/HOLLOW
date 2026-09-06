import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/core/providers/channel_chat_provider.dart';

enum GuestFetchMode {
  realtime,
  onLaunch,
  manual,
  periodic5m,
  periodic15m,
  periodic30m,
  periodic1h;

  String get label => switch (this) {
        realtime => 'Real-time',
        onLaunch => 'On launch',
        manual => 'Manual',
        periodic5m => 'Every 5 min',
        periodic15m => 'Every 15 min',
        periodic30m => 'Every 30 min',
        periodic1h => 'Every hour',
      };

  Duration? get interval => switch (this) {
        periodic5m => const Duration(minutes: 5),
        periodic15m => const Duration(minutes: 15),
        periodic30m => const Duration(minutes: 30),
        periodic1h => const Duration(hours: 1),
        _ => null,
      };

  String toJson() => name;

  static GuestFetchMode fromJson(String value) =>
      GuestFetchMode.values.firstWhere(
        (m) => m.name == value,
        orElse: () => GuestFetchMode.realtime,
      );
}

class SavedGuestServer {
  final String serverId;
  String serverName;
  GuestFetchMode fetchMode;
  final DateTime savedAt;

  SavedGuestServer({
    required this.serverId,
    required this.serverName,
    required this.fetchMode,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() => {
        'server_id': serverId,
        'server_name': serverName,
        'fetch_mode': fetchMode.toJson(),
        'saved_at': savedAt.millisecondsSinceEpoch,
      };

  factory SavedGuestServer.fromJson(Map<String, dynamic> json) =>
      SavedGuestServer(
        serverId: json['server_id'] as String,
        serverName: json['server_name'] as String? ?? '',
        fetchMode: GuestFetchMode.fromJson(
            json['fetch_mode'] as String? ?? 'realtime'),
        savedAt: DateTime.fromMillisecondsSinceEpoch(
            json['saved_at'] as int? ?? 0),
      );
}

class GuestChannelEntry {
  final String channelId;
  final String name;
  final String? category;

  const GuestChannelEntry({
    required this.channelId,
    required this.name,
    this.category,
  });
}

class GuestSenderProfile {
  final String name;
  final Uint8List? avatar;

  const GuestSenderProfile({required this.name, this.avatar});
}

/// Panel visibility — mirrors shareTabOpenProvider / archiveTabOpenProvider.
final guestTabOpenProvider = StateProvider<bool>((ref) => false);

/// Which server is expanded in the accordion sidebar.
final guestExpandedServerProvider = StateProvider<String?>((ref) => null);

/// Which server's channel is currently being viewed.
final guestSelectedServerProvider = StateProvider<String?>((ref) => null);

/// Which channel is being viewed.
final guestSelectedChannelProvider = StateProvider<String?>((ref) => null);

/// Per-server channel lists (key: serverId).
final guestChannelMapProvider = StateNotifierProvider<
    GuestChannelMapNotifier, Map<String, List<GuestChannelEntry>>>(
  (ref) => GuestChannelMapNotifier(),
);

/// Per-channel "has more messages" flag (key: `serverId:channelId`).
final guestHasMoreProvider = StateProvider<Map<String, bool>>((ref) => {});

/// Which servers are currently loading their channel list.
final guestLoadingProvider = StateProvider<Set<String>>((ref) => {});

/// Server avatars received from guest sync (key: serverId, value: image bytes).
final guestServerAvatarProvider = StateProvider<Map<String, List<int>>>((ref) => {});

/// Server banner THUMBNAILS received from guest sync (key: serverId, value:
/// 400x133 still WebP bytes — pre-join surfaces never get the full banner).
final guestServerBannerProvider = StateProvider<Map<String, List<int>>>((ref) => {});

/// Guest sender profiles keyed by peer ID (populated from sync responses).
final guestSenderProfilesProvider = StateProvider<Map<String, GuestSenderProfile>>((ref) => {});

/// DB-backed saved server list.
final savedGuestServersProvider = AsyncNotifierProvider<
    SavedGuestServersNotifier, List<SavedGuestServer>>(
  SavedGuestServersNotifier.new,
);

class GuestChannelMapNotifier
    extends StateNotifier<Map<String, List<GuestChannelEntry>>> {
  GuestChannelMapNotifier() : super({});

  void setChannels(String serverId, List<GuestChannelEntry> channels) {
    state = {...state, serverId: channels};
  }

  void addChannel(String serverId, GuestChannelEntry channel) {
    final channels = state[serverId] ?? [];
    if (channels.any((c) => c.channelId == channel.channelId)) return;
    state = {...state, serverId: [...channels, channel]};
  }

  void removeChannel(String serverId, String channelId) {
    final channels = state[serverId];
    if (channels == null) return;
    state = {...state, serverId: channels.where((c) => c.channelId != channelId).toList()};
  }

  void removeServer(String serverId) {
    final updated = Map.of(state);
    updated.remove(serverId);
    state = updated;
  }

  void clear() => state = {};
}

const _maxRealtimeServers = 7;

class SavedGuestServersNotifier extends AsyncNotifier<List<SavedGuestServer>> {
  static const _key = 'guest_saved_servers';

  @override
  Future<List<SavedGuestServer>> build() async {
    final json = await storage_api.loadSetting(key: _key);
    if (json == null || json.isEmpty) return [];
    try {
      final list = (jsonDecode(json) as List)
          .map((e) => SavedGuestServer.fromJson(e as Map<String, dynamic>))
          .toList();
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> _persist(List<SavedGuestServer> servers) async {
    await storage_api.saveSetting(
      key: _key,
      value: jsonEncode(servers.map((s) => s.toJson()).toList()),
    );
    state = AsyncData(servers);
  }

  /// Returns true if added, false if duplicate or realtime cap exceeded.
  Future<bool> addServer(
      String serverId, String serverName, GuestFetchMode mode) async {
    final current = state.valueOrNull ?? [];
    if (current.any((s) => s.serverId == serverId)) return false;
    final realtimeCount =
        current.where((s) => s.fetchMode == GuestFetchMode.realtime).length;
    if (mode == GuestFetchMode.realtime &&
        realtimeCount >= _maxRealtimeServers) {
      return false;
    }
    final server = SavedGuestServer(
      serverId: serverId,
      serverName: serverName,
      fetchMode: mode,
      savedAt: DateTime.now(),
    );
    await _persist([...current, server]);
    return true;
  }

  Future<void> removeServer(String serverId) async {
    final current = state.valueOrNull ?? [];
    final updated = current.where((s) => s.serverId != serverId).toList();
    crdt_api.leaveGuestRoom(serverId: serverId);
    ref.read(channelChatProvider.notifier).clearGuestServer(serverId);
    ref.read(guestChannelMapProvider.notifier).removeServer(serverId);
    final selectedServer = ref.read(guestSelectedServerProvider);
    if (selectedServer == serverId) {
      ref.read(guestSelectedServerProvider.notifier).state = null;
      ref.read(guestSelectedChannelProvider.notifier).state = null;
    }
    final expanded = ref.read(guestExpandedServerProvider);
    if (expanded == serverId) {
      ref.read(guestExpandedServerProvider.notifier).state = null;
    }
    await _persist(updated);
  }

  /// Returns true if updated, false if realtime cap exceeded.
  Future<bool> updateFetchMode(
      String serverId, GuestFetchMode newMode) async {
    final current = state.valueOrNull ?? [];
    final idx = current.indexWhere((s) => s.serverId == serverId);
    if (idx < 0) return false;
    final old = current[idx];
    if (old.fetchMode == newMode) return true;
    if (newMode == GuestFetchMode.realtime) {
      final realtimeCount =
          current.where((s) => s.fetchMode == GuestFetchMode.realtime).length;
      if (realtimeCount >= _maxRealtimeServers) return false;
    }
    final updated = List<SavedGuestServer>.from(current);
    updated[idx].fetchMode = newMode;
    if (newMode == GuestFetchMode.realtime ||
        newMode == GuestFetchMode.onLaunch ||
        newMode.interval != null) {
      crdt_api.requestPublicChannels(serverId: serverId).catchError((_) {});
    } else if (newMode == GuestFetchMode.manual &&
        old.fetchMode == GuestFetchMode.realtime) {
      crdt_api.leaveGuestRoom(serverId: serverId);
    }
    await _persist(updated);
    return true;
  }

  Future<void> updateServerName(String serverId, String name) async {
    final current = state.valueOrNull ?? [];
    final idx = current.indexWhere((s) => s.serverId == serverId);
    if (idx < 0) return;
    if (current[idx].serverName == name) return;
    final updated = List<SavedGuestServer>.from(current);
    updated[idx].serverName = name;
    await _persist(updated);
  }

  int get realtimeCount =>
      (state.valueOrNull ?? [])
          .where((s) => s.fetchMode == GuestFetchMode.realtime)
          .length;
}

Future<void> autoJoinGuestRooms(Ref ref) async {
  final servers = await ref.read(savedGuestServersProvider.future);
  for (final server in servers) {
    if (server.fetchMode == GuestFetchMode.realtime ||
        server.fetchMode == GuestFetchMode.onLaunch) {
      // Fire-and-forget — swallow the async rejection (e.g. node stopped
      // between start() and this running) instead of crashing the zone.
      crdt_api
          .requestPublicChannels(serverId: server.serverId)
          .catchError((_) {});
    }
  }
}

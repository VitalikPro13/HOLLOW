import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// Manages the channel list for the currently selected server.
class ChannelListNotifier extends Notifier<Map<String, ChannelInfo>> {
  @override
  Map<String, ChannelInfo> build() => {};

  /// Load channels for a server from the local DB.
  Future<void> loadForServer(String serverId) async {
    try {
      final channels = await crdt_api.getServerChannels(serverId: serverId);
      final map = <String, ChannelInfo>{};
      for (final ch in channels) {
        map[ch.channelId] = ChannelInfo(
          channelId: ch.channelId,
          name: ch.name,
          category: ch.category,
          channelType: ch.channelType == 'voice'
              ? ChannelType.voice
              : ChannelType.text,
        );
      }
      state = map;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load channels: $e');
    }
  }

  /// Called when a ChannelAdded event arrives.
  void onChannelAdded(String serverId, String channelId, String name,
      {String channelType = 'text'}) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    final updated = Map.of(state);
    updated[channelId] = ChannelInfo(
      channelId: channelId,
      name: name,
      channelType:
          channelType == 'voice' ? ChannelType.voice : ChannelType.text,
    );
    state = updated;
  }

  /// Called when a ChannelRemoved event arrives.
  void onChannelRemoved(String serverId, String channelId) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    state = Map.of(state)..remove(channelId);
  }

  /// Called when a ChannelRenamed event arrives.
  void onChannelRenamed(String serverId, String channelId, String newName) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    final existing = state[channelId];
    if (existing == null) return;

    final updated = Map.of(state);
    updated[channelId] = ChannelInfo(
      channelId: channelId,
      name: newName,
      category: existing.category,
    );
    state = updated;
  }

  /// Clear channel list (e.g., when switching servers).
  void clear() {
    state = {};
  }
}

final channelListProvider =
    NotifierProvider<ChannelListNotifier, Map<String, ChannelInfo>>(
        ChannelListNotifier.new);

/// Currently selected channel ID.
final selectedChannelProvider = StateProvider<String?>((ref) => null);

/// Remembers the last selected channel per server so switching back restores it.
final lastChannelPerServerProvider =
    StateProvider<Map<String, String>>((ref) => {});

/// Channel layout JSON for the currently selected server.
/// Updated when channels load or server layout changes.
class ChannelLayoutNotifier extends Notifier<String> {
  @override
  String build() => '[]';

  Future<void> loadForServer(String serverId) async {
    try {
      final json = await crdt_api.getChannelLayout(serverId: serverId);
      state = json;
    } catch (_) {
      state = '[]';
    }
  }

  void clear() => state = '[]';
}

final channelLayoutProvider =
    NotifierProvider<ChannelLayoutNotifier, String>(ChannelLayoutNotifier.new);

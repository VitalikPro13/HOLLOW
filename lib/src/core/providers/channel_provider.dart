import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/channel_info.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/rust/api/crdt.dart' as crdt_api;

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
        );
      }
      state = map;
    } catch (e) {
      debugPrint('[HAVEN] Failed to load channels: $e');
    }
  }

  /// Called when a ChannelAdded event arrives.
  void onChannelAdded(String serverId, String channelId, String name) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    state = {
      ...state,
      channelId: ChannelInfo(channelId: channelId, name: name),
    };
  }

  /// Called when a ChannelRemoved event arrives.
  void onChannelRemoved(String serverId, String channelId) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    state = Map.of(state)..remove(channelId);
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

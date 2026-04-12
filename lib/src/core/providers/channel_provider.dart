import 'dart:convert';

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
      state = await fetchChannels(serverId);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load channels: $e');
    }
  }

  /// Fetch channels without publishing to state. Callers can batch
  /// multiple provider updates to avoid intermediate rebuilds.
  static Future<Map<String, ChannelInfo>> fetchChannels(String serverId) async {
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
    return map;
  }

  /// Set channels directly (used for batched provider updates).
  void setChannels(Map<String, ChannelInfo> channels) {
    state = channels;
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
      state = await fetchLayout(serverId);
    } catch (_) {
      state = '[]';
    }
  }

  /// Fetch layout without publishing to state.
  static Future<String> fetchLayout(String serverId) async {
    return await crdt_api.getChannelLayout(serverId: serverId);
  }

  /// Set layout directly (used for batched provider updates).
  void setLayout(String json) {
    state = json;
  }

  void clear() => state = '[]';
}

final channelLayoutProvider =
    NotifierProvider<ChannelLayoutNotifier, String>(ChannelLayoutNotifier.new);

/// Returns the first text channel ID in visual sidebar order, or null if none.
/// Mirrors the sidebar rendering: placed channels (layout order) first,
/// then unplaced channels (alphabetical).
String? firstTextChannelInLayout(
    Map<String, ChannelInfo> channels, String layoutJson) {
  final placedIds = <String>{};

  // 1. Walk placed channels in layout order.
  try {
    final List<dynamic> layout = jsonDecode(layoutJson);
    for (final item in layout) {
      if (item['type'] == 'channel') {
        final id = item['channel_id'] as String;
        placedIds.add(id);
        final ch = channels[id];
        if (ch != null && ch.channelType == ChannelType.text) return id;
      }
    }
  } catch (_) {}

  // 2. Walk unplaced channels in alphabetical order (same as sidebar).
  final unplaced = channels.values
      .where((ch) => !placedIds.contains(ch.channelId))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  for (final ch in unplaced) {
    if (ch.channelType == ChannelType.text) return ch.channelId;
  }

  return null;
}

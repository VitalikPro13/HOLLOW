import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/channel_chat_message.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/service_providers.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;

/// Manages channel message state, keyed by "serverId:channelId".
class ChannelChatNotifier
    extends Notifier<Map<String, List<ChannelChatMessage>>> {
  @override
  Map<String, List<ChannelChatMessage>> build() => {};

  String _key(String serverId, String channelId) => '$serverId:$channelId';

  /// Send a message to a channel.
  Future<void> sendMessage(
      String serverId, String channelId, String text) async {
    final networkService = ref.read(networkServiceProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? 'unknown';

    // Rust will generate the timestamp and persist to DB.
    await networkService.sendChannelMessage(
      serverId: serverId,
      channelId: channelId,
      text: text,
    );

    // Add to in-memory state for instant UI feedback.
    final now = DateTime.now();
    final msg = ChannelChatMessage(
      senderId: localPeerId,
      text: text,
      isMe: true,
      timestamp: now,
    );
    _addMessage(serverId, channelId, msg);
  }

  /// Receive a message from a peer in a channel.
  /// Called only for genuinely new messages (Rust deduplicates before emitting).
  /// [timestampMs] is the sender's original timestamp in milliseconds.
  void receiveMessage(String serverId, String channelId, String fromPeer,
      String text, int timestampMs) {
    final key = _key(serverId, channelId);
    final existing = state[key] ?? [];

    // Extra safety: skip if we already have this exact message in memory.
    final ts = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final isDuplicate = existing.any(
        (m) => m.senderId == fromPeer && m.text == text && m.timestamp == ts);
    if (isDuplicate) return;

    final msg = ChannelChatMessage(
      senderId: fromPeer,
      text: text,
      isMe: false,
      timestamp: ts,
    );
    _addMessage(serverId, channelId, msg);
    // No DB save here — Rust already persisted before emitting the event.
  }

  /// Load history for a channel from SQLCipher.
  /// Also requests a background sync from connected peers.
  Future<void> loadHistory(String serverId, String channelId) async {
    // Always request sync from connected peers when opening a channel.
    // New messages arrive via MessageSyncCompleted → cache clear → reload.
    try {
      network_api.requestChannelSync(
          serverId: serverId, channelId: channelId);
    } catch (_) {}

    try {
      final stored =
          await ref.read(storageServiceProvider).loadChannelMessages(
                serverId: serverId,
                channelId: channelId,
                limit: 200,
              );
      if (stored.isNotEmpty) {
        final messages = stored
            .map((m) => ChannelChatMessage(
                  senderId: m.senderId,
                  text: m.text,
                  isMe: m.isMine,
                  timestamp:
                      DateTime.fromMillisecondsSinceEpoch(m.timestamp),
                ))
            .toList();

        // Replace state entirely — DB is the source of truth.
        final key = _key(serverId, channelId);
        final updated = Map.of(state);
        updated[key] = messages;
        state = updated;
      }
    } catch (e) {
      debugPrint('[HAVEN] Failed to load channel history: $e');
    }
  }

  /// Clear cached messages for a server (forces reload from DB on next view).
  void clearServerCache(String serverId) {
    final updated = Map.of(state);
    updated.removeWhere((key, _) => key.startsWith('$serverId:'));
    state = updated;
  }

  void _addMessage(
      String serverId, String channelId, ChannelChatMessage message) {
    final key = _key(serverId, channelId);
    final current = state[key] ?? [];
    final updated = Map.of(state);
    updated[key] = [...current, message];
    state = updated;
  }
}

final channelChatProvider = NotifierProvider<ChannelChatNotifier,
    Map<String, List<ChannelChatMessage>>>(ChannelChatNotifier.new);

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/chat_provider.dart' show generateMessageId;
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Manages channel message state, keyed by "serverId:channelId".
class ChannelChatNotifier
    extends Notifier<Map<String, List<ChannelChatMessage>>> {
  @override
  Map<String, List<ChannelChatMessage>> build() => {};

  String _key(String serverId, String channelId) => '$serverId:$channelId';

  /// Send a message to a channel.
  Future<void> sendMessage(String serverId, String channelId, String text,
      {String? replyToMid}) async {
    final networkService = ref.read(networkServiceProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? 'unknown';
    final messageId = generateMessageId();

    // Rust will generate the timestamp and persist to DB.
    await networkService.sendChannelMessage(
      serverId: serverId,
      channelId: channelId,
      text: text,
      messageId: messageId,
      replyToMid: replyToMid,
    );

    // Add to in-memory state for instant UI feedback.
    final now = DateTime.now();
    final msg = ChannelChatMessage(
      senderId: localPeerId,
      text: text,
      isMe: true,
      timestamp: now,
      messageId: messageId,
      replyToMid: replyToMid,
    );
    _addMessage(serverId, channelId, msg);
  }

  /// Receive a message from a peer in a channel.
  /// Called only for genuinely new messages (Rust deduplicates before emitting).
  /// [timestampMs] is the sender's original timestamp in milliseconds.
  void receiveMessage(String serverId, String channelId, String fromPeer,
      String text, int timestampMs, String messageId, String replyToMid) {
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
      messageId: messageId.isNotEmpty ? messageId : null,
      replyToMid: replyToMid.isNotEmpty ? replyToMid : null,
    );
    _addMessage(serverId, channelId, msg);
    // No DB save here — Rust already persisted before emitting the event.
  }

  /// Edit a channel message.
  Future<void> editMessage(String serverId, String channelId,
      String messageId, String newText) async {
    await network_api.editChannelMessage(
      serverId: serverId,
      channelId: channelId,
      messageId: messageId,
      newText: newText,
    );
    // UI update happens via the ChannelMessageEdited event.
  }

  /// Apply an edit to an in-memory message (from network event or own edit).
  void applyEdit(String serverId, String channelId, String messageId,
      String newText, int editedAtMs) {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current == null) return;

    final editedAt = DateTime.fromMillisecondsSinceEpoch(editedAtMs);
    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;

    final updatedList = List<ChannelChatMessage>.from(current);
    updatedList[idx] =
        updatedList[idx].copyWith(text: newText, editedAt: editedAt);
    final updated = Map.of(state);
    updated[key] = updatedList;
    state = updated;
  }

  /// Delete (hide) a channel message.
  Future<void> deleteMessage(String serverId, String channelId,
      String messageId) async {
    await network_api.deleteChannelMessage(
      serverId: serverId,
      channelId: channelId,
      messageId: messageId,
    );
    // UI update happens via the ChannelMessageDeleted event.
  }

  /// Remove a message from in-memory state (from network event or own deletion).
  void applyDelete(String serverId, String channelId, String messageId,
      int deletedAtMs) {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current == null) return;

    final updatedList =
        current.where((m) => m.messageId != messageId).toList();
    if (updatedList.length == current.length) return; // Not found.

    final updated = Map.of(state);
    updated[key] = updatedList;
    state = updated;
  }

  /// Add an emoji reaction to a channel message.
  /// Enforces 3 distinct emoji limit per user per message.
  Future<void> addReaction(String serverId, String channelId,
      String messageId, String emoji) async {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current != null) {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final idx = current.indexWhere((m) => m.messageId == messageId);
      if (idx != -1) {
        final msg = current[idx];
        final myDistinct = msg.reactions.entries
            .where((e) => e.value.contains(localPeerId) && e.key != emoji)
            .length;
        if (myDistinct >= 3) return;
      }
    }
    await network_api.addChannelReaction(
      serverId: serverId,
      channelId: channelId,
      messageId: messageId,
      emoji: emoji,
    );
  }

  /// Remove an emoji reaction from a channel message.
  Future<void> removeReaction(String serverId, String channelId,
      String messageId, String emoji) async {
    await network_api.removeChannelReaction(
      serverId: serverId,
      channelId: channelId,
      messageId: messageId,
      emoji: emoji,
    );
  }

  /// Apply an incoming reaction add to in-memory state.
  void applyAddReaction(String serverId, String channelId,
      String messageId, String emoji, String reactorPeerId) {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current == null) return;

    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;

    final msg = current[idx];
    final reactions = Map<String, List<String>>.from(
        msg.reactions.map((k, v) => MapEntry(k, List<String>.from(v))));
    final reactors = reactions[emoji] ?? [];
    if (reactors.contains(reactorPeerId)) return;
    reactions[emoji] = [...reactors, reactorPeerId];

    final updatedList = List<ChannelChatMessage>.from(current);
    updatedList[idx] = msg.copyWith(reactions: reactions);
    final updated = Map.of(state);
    updated[key] = updatedList;
    state = updated;
  }

  /// Apply an incoming reaction removal to in-memory state.
  void applyRemoveReaction(String serverId, String channelId,
      String messageId, String emoji, String reactorPeerId) {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current == null) return;

    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;

    final msg = current[idx];
    final reactions = Map<String, List<String>>.from(
        msg.reactions.map((k, v) => MapEntry(k, List<String>.from(v))));
    final reactors = reactions[emoji];
    if (reactors == null) return;
    reactors.remove(reactorPeerId);
    if (reactors.isEmpty) {
      reactions.remove(emoji);
    } else {
      reactions[emoji] = reactors;
    }

    final updatedList = List<ChannelChatMessage>.from(current);
    updatedList[idx] = msg.copyWith(reactions: reactions);
    final updated = Map.of(state);
    updated[key] = updatedList;
    state = updated;
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
                limit: 500,
              );
      if (stored.isNotEmpty) {
        // Collect message IDs for bulk reaction loading.
        final messageIds = stored
            .where((m) => m.messageId != null)
            .map((m) => m.messageId!)
            .toList();

        Map<String, Map<String, List<String>>> reactionsMap = {};
        if (messageIds.isNotEmpty) {
          try {
            final storedReactions =
                await storage_api.loadReactions(messageIds: messageIds);
            for (final r in storedReactions) {
              reactionsMap
                  .putIfAbsent(r.messageId, () => {})
                  .putIfAbsent(r.emoji, () => [])
                  .add(r.peerId);
            }
          } catch (_) {}
        }

        // Load file attachments for messages that have file_id.
        final fileIds = stored
            .where((m) => m.fileId != null)
            .map((m) => m.fileId!)
            .toSet();
        Map<String, FileAttachment> fileMap = {};
        for (final fid in fileIds) {
          try {
            final info = await storage_api.getFileMetadata(fileId: fid);
            if (info != null) {
              fileMap[fid] = FileAttachment(
                fileId: info.fileId,
                fileName: info.fileName,
                fileExt: info.fileExt,
                mimeType: info.mimeType,
                sizeBytes: info.sizeBytes.toInt(),
                isImage: info.isImage,
                width: info.width?.toInt(),
                height: info.height?.toInt(),
                totalChunks: info.chunkCount,
                chunksReceived: info.chunksReceived,
                isComplete: info.completedAt != null,
                diskPath: info.diskPath,
              );
            }
          } catch (_) {}
        }

        final messages = stored
            .map((m) => ChannelChatMessage(
                  senderId: m.senderId,
                  text: m.text,
                  isMe: m.isMine,
                  timestamp:
                      DateTime.fromMillisecondsSinceEpoch(m.timestamp),
                  signature: m.signature,
                  publicKey: m.publicKey,
                  messageId: m.messageId,
                  editedAt: m.editedAt != null
                      ? DateTime.fromMillisecondsSinceEpoch(m.editedAt!)
                      : null,
                  replyToMid: m.replyToMid,
                  reactions: m.messageId != null
                      ? reactionsMap[m.messageId]
                      : null,
                  fileAttachment: m.fileId != null
                      ? fileMap[m.fileId]
                      : null,
                ))
            .toList();

        // Replace state entirely — DB is the source of truth.
        final key = _key(serverId, channelId);
        final updated = Map.of(state);
        updated[key] = messages;
        state = updated;
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load channel history: $e');
    }
  }

  /// Reload reactions from DB for the current in-memory messages.
  /// Does NOT trigger a sync request — safe to call from sync completion.
  Future<void> reloadReactions(String serverId, String channelId) async {
    final key = _key(serverId, channelId);
    final messages = state[key];
    if (messages == null || messages.isEmpty) return;

    final messageIds = messages
        .where((m) => m.messageId != null)
        .map((m) => m.messageId!)
        .toList();
    if (messageIds.isEmpty) return;

    try {
      final storedReactions =
          await storage_api.loadReactions(messageIds: messageIds);
      Map<String, Map<String, List<String>>> reactionsMap = {};
      for (final r in storedReactions) {
        reactionsMap
            .putIfAbsent(r.messageId, () => {})
            .putIfAbsent(r.emoji, () => [])
            .add(r.peerId);
      }

      final updated = Map.of(state);
      updated[key] = messages
          .map((m) => m.copyWith(
                reactions: m.messageId != null
                    ? reactionsMap[m.messageId]
                    : null,
              ))
          .toList();
      state = updated;
    } catch (_) {}
  }

  /// Clear cached messages for a server (forces reload from DB on next view).
  void clearServerCache(String serverId) {
    final updated = Map.of(state);
    updated.removeWhere((key, _) => key.startsWith('$serverId:'));
    state = updated;
  }

  /// Add a file message optimistically (sender side).
  void addFileMessage(
    String serverId,
    String channelId,
    String messageId,
    String fileName,
    int sizeBytes,
    String ext,
    bool isImage,
    String localPath,
  ) {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    _addMessage(
      serverId,
      channelId,
      ChannelChatMessage(
        senderId: localPeerId,
        text: '',
        isMe: true,
        messageId: messageId,
        fileAttachment: FileAttachment(
          fileId: messageId,
          fileName: fileName,
          fileExt: ext,
          mimeType: 'application/octet-stream',
          sizeBytes: sizeBytes,
          isImage: isImage,
          totalChunks: 0,
          isComplete: true,
          diskPath: localPath,
        ),
      ),
    );
  }

  /// Max messages kept in memory per channel.
  static const _maxMessages = 500;

  void _addMessage(
      String serverId, String channelId, ChannelChatMessage message) {
    final key = _key(serverId, channelId);
    final current = state[key] ?? <ChannelChatMessage>[];
    var list = <ChannelChatMessage>[...current, message];
    // Trim oldest messages to prevent unbounded memory growth.
    if (list.length > _maxMessages) {
      list = list.sublist(list.length - _maxMessages);
    }
    final updated = Map.of(state);
    updated[key] = list;
    state = updated;
  }
}

final channelChatProvider = NotifierProvider<ChannelChatNotifier,
    Map<String, List<ChannelChatMessage>>>(ChannelChatNotifier.new);

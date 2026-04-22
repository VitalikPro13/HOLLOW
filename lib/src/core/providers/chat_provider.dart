import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Generate a 32-char hex message ID (same format as Rust's 16-byte random).
String generateMessageId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class ChatNotifier extends Notifier<Map<String, List<ChatMessage>>> {
  @override
  Map<String, List<ChatMessage>> build() => {};

  /// Send a message to a peer (FFI + update state).
  /// DB persistence happens in Rust (SendMessage handler) with Rust-generated timestamp.
  Future<void> sendMessage(String peerId, String text,
      {String? replyToMid, network_api.LinkPreviewRef? linkPreview}) async {
    final networkService = ref.read(networkServiceProvider);
    final messageId = generateMessageId();

    await networkService.sendMessage(
      peerId: peerId,
      text: text,
      messageId: messageId,
      replyToMid: replyToMid,
      linkPreview: linkPreview,
    );

    final now = DateTime.now();
    final msg = ChatMessage(
      text: text,
      isMe: true,
      timestamp: now,
      messageId: messageId,
      replyToMid: replyToMid,
      linkPreview: linkPreview,
    );

    _addMessage(peerId, msg);
  }

  /// Receive a message from a peer (from network events).
  /// DB persistence happens in Rust (DirectMessage handler) with sender's timestamp.
  void receiveMessage(String fromPeer, String text, int timestamp,
      String messageId, String replyToMid,
      {network_api.LinkPreviewRef? linkPreview,
      String? signature,
      String? publicKey}) {
    final ts = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final msg = ChatMessage(
      text: text,
      isMe: false,
      timestamp: ts,
      messageId: messageId.isNotEmpty ? messageId : null,
      replyToMid: replyToMid.isNotEmpty ? replyToMid : null,
      linkPreview: linkPreview,
      signature: signature,
      publicKey: publicKey,
    );
    _addMessage(fromPeer, msg);
  }

  /// Hydrate signature, public key, and (critically) timestamp on an existing
  /// in-memory message. Called from the MessageSent event handler after Rust
  /// has signed+persisted the message — we overwrite the optimistic Dart-side
  /// `DateTime.now()` timestamp with Rust's exact `SystemTime::now()` value
  /// that the signature was actually computed over. Without the timestamp
  /// replacement, the Dart verifier reconstructs the canonical payload with a
  /// slightly different millisecond, which breaks signature verification on
  /// machines with coarse OS timer resolution (e.g. VMs).
  void hydrateSignature(String peerId, String messageId, int timestampMs,
      String? signature, String? publicKey) {
    final current = state[peerId];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;
    final updatedList = List<ChatMessage>.from(current);
    updatedList[idx] = updatedList[idx].copyWith(
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      signature: signature,
      publicKey: publicKey,
    );
    final updated = Map.of(state);
    updated[peerId] = updatedList;
    state = updated;
  }

  /// Edit a message we sent.
  Future<void> editMessage(
      String peerId, String messageId, String newText) async {
    await network_api.editDmMessage(
      peerId: peerId,
      messageId: messageId,
      newText: newText,
    );
    // UI update happens via the DmMessageEdited event.
  }

  /// Apply an edit to an in-memory message (from network event or own edit).
  /// Updates signature + publicKey alongside text so the Message Proof dialog
  /// verifies against the edit's own signature, not the original's.
  void applyEdit(
      String peerId, String messageId, String newText, int editedAtMs,
      {String? signature, String? publicKey}) {
    final current = state[peerId];
    if (current == null) return;

    final editedAt = DateTime.fromMillisecondsSinceEpoch(editedAtMs);
    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;

    final updatedList = List<ChatMessage>.from(current);
    updatedList[idx] = updatedList[idx].copyWith(
      text: newText,
      editedAt: editedAt,
      signature: signature,
      publicKey: publicKey,
    );
    final updated = Map.of(state);
    updated[peerId] = updatedList;
    state = updated;
  }

  /// Delete (hide) a message we sent.
  Future<void> deleteMessage(String peerId, String messageId) async {
    await network_api.deleteDmMessage(
      peerId: peerId,
      messageId: messageId,
    );
    // UI update happens via the DmMessageDeleted event.
  }

  /// Remove a message from in-memory state (from network event or own deletion).
  void applyDelete(String peerId, String messageId, int deletedAtMs) {
    final current = state[peerId];
    if (current == null) return;

    final updatedList =
        current.where((m) => m.messageId != messageId).toList();
    if (updatedList.length == current.length) return; // Not found.

    final updated = Map.of(state);
    updated[peerId] = updatedList;
    state = updated;
  }

  /// Add an emoji reaction to a DM message.
  /// Enforces 3 distinct emoji limit per user per message.
  Future<void> addReaction(
      String peerId, String messageId, String emoji) async {
    // Check limit client-side before sending.
    final current = state[peerId];
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
    await network_api.addDmReaction(
      peerId: peerId,
      messageId: messageId,
      emoji: emoji,
    );
  }

  /// Remove an emoji reaction from a DM message.
  Future<void> removeReaction(
      String peerId, String messageId, String emoji) async {
    await network_api.removeDmReaction(
      peerId: peerId,
      messageId: messageId,
      emoji: emoji,
    );
  }

  /// Apply an incoming reaction add to in-memory state.
  void applyAddReaction(
      String peerId, String messageId, String emoji, String reactorPeerId) {
    final current = state[peerId];
    if (current == null) return;

    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;

    final msg = current[idx];
    final reactions = Map<String, List<String>>.from(
        msg.reactions.map((k, v) => MapEntry(k, List<String>.from(v))));
    final reactors = reactions[emoji] ?? [];
    if (reactors.contains(reactorPeerId)) return; // Already reacted.
    reactions[emoji] = [...reactors, reactorPeerId];

    final updatedList = List<ChatMessage>.from(current);
    updatedList[idx] = msg.copyWith(reactions: reactions);
    final updated = Map.of(state);
    updated[peerId] = updatedList;
    state = updated;
  }

  /// Apply an incoming reaction removal to in-memory state.
  void applyRemoveReaction(
      String peerId, String messageId, String emoji, String reactorPeerId) {
    final current = state[peerId];
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

    final updatedList = List<ChatMessage>.from(current);
    updatedList[idx] = msg.copyWith(reactions: reactions);
    final updated = Map.of(state);
    updated[peerId] = updatedList;
    state = updated;
  }

  /// Add a send-failure message (shown as a local system message).
  void addSendFailure(String toPeer, String error) {
    _addMessage(
      toPeer,
      ChatMessage(text: '[Failed to send: $error]', isMe: true),
    );
  }

  /// Load chat history from SQLCipher for a peer.
  Future<void> loadHistory(String peerId) async {
    try {
      final storageService = ref.read(storageServiceProvider);
      final stored = await storageService.loadMessages(
        peerId: peerId,
        limit: 200,
      );

      // Collect message IDs for bulk reaction loading.
      final messageIds = stored
          .where((m) => m.messageId != null)
          .map((m) => m.messageId!)
          .toList();

      // Load reactions in one batch.
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
              videoThumb: info.videoThumb,
              expiredAt: info.expiredAt?.toInt(),
            );
          }
        } catch (_) {}
      }

      final messages = stored
          .map((m) => ChatMessage(
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
                linkPreview: m.linkPreview,
              ))
          .toList();

      // DB is the source of truth, but preserve any in-memory messages
      // (by messageId) that aren't in the DB snapshot yet — covers the
      // tiny race where a message arrives mid-load, and keeps optimistic
      // in-flight sends that haven't round-tripped through Rust.
      final existing = state[peerId] ?? const <ChatMessage>[];
      final loadedIds = messages
          .where((m) => m.messageId != null)
          .map((m) => m.messageId!)
          .toSet();
      final carryOver = existing
          .where((m) => m.messageId != null && !loadedIds.contains(m.messageId))
          .toList();
      final merged = [...messages, ...carryOver]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final updated = Map.of(state);
      updated[peerId] = merged;
      state = updated;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load history for $peerId: $e');
    }
  }

  /// Add a file message optimistically (sender side).
  void addFileMessage(
    String peerId,
    String messageId,
    String fileName,
    int sizeBytes,
    String ext,
    bool isImage,
    String localPath, {
    String text = '',
  }) {
    _addMessage(
      peerId,
      ChatMessage(
        text: text,
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

  /// Update a message's file attachment (e.g., when file transfer completes).
  void updateFileAttachment(String peerId, String fileId, FileAttachment attachment) {
    final messages = state[peerId];
    if (messages == null) return;
    final updated = messages.map((m) {
      if (m.fileAttachment?.fileId == fileId) {
        return m.copyWith(fileAttachment: attachment);
      }
      return m;
    }).toList();
    final map = Map.of(state);
    map[peerId] = updated;
    state = map;
  }

  /// Clear cached messages for a peer (forces reload from DB on next view).
  void clearPeerCache(String peerId) {
    final updated = Map.of(state);
    updated.remove(peerId);
    state = updated;
  }

  /// Max messages kept in memory per conversation.
  static const _maxMessages = 200;

  void _addMessage(String peerId, ChatMessage message) {
    final current = state[peerId] ?? <ChatMessage>[];
    var list = <ChatMessage>[...current, message];
    // Trim oldest messages to prevent unbounded memory growth.
    if (list.length > _maxMessages) {
      list = list.sublist(list.length - _maxMessages);
    }
    final updated = Map.of(state);
    updated[peerId] = list;
    state = updated;
  }
}

final chatProvider =
    NotifierProvider<ChatNotifier, Map<String, List<ChatMessage>>>(
        ChatNotifier.new);

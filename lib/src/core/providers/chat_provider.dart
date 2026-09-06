import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
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

  /// Send a message to a peer; Rust persists it with its own timestamp.
  ///
  /// Returns the generated message id so a caller that sent before its link
  /// preview finished fetching can attach the card afterwards (issue #45).
  Future<String> sendMessage(String peerId, String text,
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

    // Being the last to speak clears our own unread state for this DM: otherwise
    // `seen:dm:{peer}` stays pinned before our latest activity and the pill lights.
    ref.read(unreadProvider.notifier).markDmSeen(peerId, messageId);
    return messageId;
  }

  /// Receive a message from a peer; Rust persists it with the sender's timestamp.
  void receiveMessage(String fromPeer, String text, int timestamp,
      String messageId, String replyToMid,
      {network_api.LinkPreviewRef? linkPreview,
      String? signature,
      String? publicKey,
      bool isOwn = false}) {
    // Multi-device self fan-out: `isOwn` means this is an echo of a message WE
    // sent from a sibling, so `fromPeer` is the recipient and it must render as
    // OUTGOING. Without this a sibling shows our own message as the friend's.
    final ts = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final msg = ChatMessage(
      text: text,
      isMe: isOwn,
      timestamp: ts,
      messageId: messageId.isNotEmpty ? messageId : null,
      replyToMid: replyToMid.isNotEmpty ? replyToMid : null,
      linkPreview: linkPreview,
      signature: signature,
      publicKey: publicKey,
    );
    // Dedup by message_id: the same message arrives from loadHistory (the DB, as
    // written by the background push-fetch node) AND as a live event. The loaded
    // copy is authoritative, since it reflects any edit already applied.
    if (msg.messageId != null) {
      final current = state[fromPeer];
      if (current != null &&
          current.any((m) => m.messageId == msg.messageId)) {
        return;
      }
    }
    _addMessage(fromPeer, msg);
  }

  /// Hydrate signature, public key and (critically) timestamp on an existing
  /// in-memory message: the optimistic Dart `DateTime.now()` is replaced with
  /// Rust's exact value that the signature was computed over, or the verifier
  /// rebuilds a different canonical payload on coarse-timer machines.
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

  /// Attach (or clear) a link preview on a DM we already sent (issue #45).
  /// Rethrows so the caller can decide whether a failure is worth surfacing —
  /// a late card that never lands is cosmetic, so the compose panes swallow it.
  Future<void> attachLinkPreview(
      String peerId, String messageId, network_api.LinkPreviewRef? preview) async {
    await network_api.attachDmLinkPreview(
      peerId: peerId,
      messageId: messageId,
      preview: preview,
    );
  }

  /// Apply a late link preview to an in-memory message. Never touches
  /// `editedAt` — a card arriving after the send is not an edit, and the
  /// bubble must not grow an "(edited)" badge because of it.
  void applyLinkPreview(
      String peerId, String messageId, network_api.LinkPreviewRef? preview) {
    final current = state[peerId];
    if (current == null) return;

    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;
    // Re-applying the same card (duplicate frame, sibling echo) is a no-op rather
    // than a pointless rebuild; LinkPreviewRef has generated value equality.
    if (current[idx].linkPreview == preview) return;

    final updatedList = List<ChatMessage>.from(current);
    updatedList[idx] = updatedList[idx].copyWith(
      linkPreview: preview,
      clearLinkPreview: preview == null,
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
              shareRootHash: info.shareRootHash,
              shareKeyHex: info.shareKeyHex,
              thumbB64: info.thumbB64,
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

      // DB is the source of truth, but preserve in-memory messages not yet in the
      // snapshot: a message arriving mid-load, and optimistic in-flight sends.
      final existing = state[peerId] ?? const <ChatMessage>[];
      final loadedIds = messages
          .where((m) => m.messageId != null)
          .map((m) => m.messageId!)
          .toSet();
      final carryOver = existing
          .where((m) => m.messageId != null && !loadedIds.contains(m.messageId))
          .toList();
      // STABLE sort: List.sort is unstable and timestamps are millisecond
      // wall-clock, so rapid messages share a millisecond and an unstable resort
      // shuffles them. Tie-break by pre-sort index instead.
      final merged = _stableSortByTimestamp([...messages, ...carryOver]);
      final updated = Map.of(state);
      updated[peerId] = merged;
      state = updated;

      // Self-heal the unread pill: if the newest message here is our own there is
      // nothing for US to read, so advance the seen-pointer to it.
      if (merged.isNotEmpty) {
        final newest = merged.last;
        if (newest.isMe && newest.messageId != null) {
          ref.read(unreadProvider.notifier).markDmSeen(peerId, newest.messageId);
        }
      }
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

  /// Load just the last message for each given peer ID (for home dashboard
  /// previews). Skips peers already in memory.
  Future<void> loadLastMessagePreviews(List<String> peerIds) async {
    final storageService = ref.read(storageServiceProvider);
    final updated = Map.of(state);
    var changed = false;
    for (final peerId in peerIds) {
      if (state.containsKey(peerId)) continue;
      try {
        final stored = await storageService.loadMessages(
          peerId: peerId,
          limit: 1,
        );
        if (stored.isNotEmpty) {
          final m = stored.first;
          updated[peerId] = [
            ChatMessage(
              text: m.text,
              isMe: m.isMine,
              timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
              messageId: m.messageId,
            ),
          ];
          changed = true;
        }
      } catch (_) {}
    }
    if (changed) state = updated;
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
    // Guard against duplicate inserts of the same identified message. Messages
    // without a messageId (system/failure notices) always append.
    if (message.messageId != null &&
        current.any((m) => m.messageId == message.messageId)) {
      return;
    }
    // Plain append in ARRIVAL order. Deliberately NOT sorted by timestamp here:
    // timestamps are the SENDER's wall clock, and across skewed machines a sort
    // reorders the live conversation. Out-of-order arrivals are fixed by the
    // `DmSyncCompleted` -> `loadHistory()` resort, which reads the DB in order.
    var list = <ChatMessage>[...current, message];
    if (list.length > _maxMessages) {
      list = list.sublist(list.length - _maxMessages);
    }
    final updated = Map.of(state);
    updated[peerId] = list;
    state = updated;
  }
}

/// Sort by timestamp with the ORIGINAL index as tie-break — a stable sort.
/// `List.sort` is unstable: messages sharing a millisecond (fast spam) would
/// otherwise swap randomly on every loadHistory merge.
List<ChatMessage> _stableSortByTimestamp(List<ChatMessage> list) {
  final entries = list.asMap().entries.toList()
    ..sort((a, b) {
      final c = a.value.timestamp.compareTo(b.value.timestamp);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return [for (final e in entries) e.value];
}

final chatProvider =
    NotifierProvider<ChatNotifier, Map<String, List<ChatMessage>>>(
        ChatNotifier.new);

/// Lightweight derived provider: only the last message per peer, so the shell
/// and sidebar don't rebuild on every message in any conversation.
///
/// A Notifier purely for [updateShouldNotify]: the recompute mints a fresh Map
/// on EVERY chatProvider mutation, so identity `==` notified the root anyway.
final lastDmMessageProvider =
    NotifierProvider<LastDmMessageNotifier, Map<String, ChatMessage>>(
        LastDmMessageNotifier.new);

class LastDmMessageNotifier extends Notifier<Map<String, ChatMessage>> {
  @override
  Map<String, ChatMessage> build() {
    final history = ref.watch(chatProvider);
    return {
      for (final entry in history.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.last,
    };
  }

  @override
  bool updateShouldNotify(
          Map<String, ChatMessage> previous, Map<String, ChatMessage> next) =>
      !mapEquals(previous, next);
}

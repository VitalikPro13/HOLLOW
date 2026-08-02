import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/chat_provider.dart' show generateMessageId;
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/conference.dart' as conference_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Manages channel message state, keyed by "serverId:channelId".
class ChannelChatNotifier
    extends Notifier<Map<String, List<ChannelChatMessage>>> {
  @override
  Map<String, List<ChannelChatMessage>> build() => {};

  String _key(String serverId, String channelId) => '$serverId:$channelId';

  /// Send a message to a channel.
  /// Returns the generated message id so a caller that sent before its link
  /// preview finished fetching can attach the card afterwards (issue #45).
  /// Conference chat returns its own RAM-only id, which no attach path uses.
  Future<String> sendMessage(String serverId, String channelId, String text,
      {String? replyToMid, network_api.LinkPreviewRef? linkPreview}) async {
    final networkService = ref.read(networkServiceProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? 'unknown';

    // Conference chat ('conf:<id>' virtual servers) is RAM-ONLY: it rides the
    // conference MLS pipeline, never the channel send path (which persists to
    // SQLCipher and fans through channel machinery). Same pane, different
    // backend — the message id is derived from the Rust Lamport stamp so an
    // improbable relay echo dedups by message_id like everything else.
    if (serverId.startsWith('conf:')) {
      final confId = serverId.substring('conf:'.length);
      final ts = await conference_api.conferenceSendChat(
          confId: confId, text: text);
      final confMid = 'conf-$localPeerId-$ts';
      _addMessage(
        serverId,
        channelId,
        ChannelChatMessage(
          senderId: localPeerId,
          text: text,
          isMe: true,
          timestamp: DateTime.fromMillisecondsSinceEpoch(ts.toInt()),
          messageId: confMid,
        ),
      );
      return confMid;
    }

    final messageId = generateMessageId();

    // Rust will generate the timestamp and persist to DB.
    await networkService.sendChannelMessage(
      serverId: serverId,
      channelId: channelId,
      text: text,
      messageId: messageId,
      replyToMid: replyToMid,
      linkPreview: linkPreview,
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
      linkPreview: linkPreview,
    );
    _addMessage(serverId, channelId, msg);
    return messageId;
  }

  /// Receive a message from a peer in a channel.
  /// Called only for genuinely new messages (Rust deduplicates before emitting).
  /// [timestampMs] is the sender's original timestamp in milliseconds.
  void receiveMessage(String serverId, String channelId, String fromPeer,
      String text, int timestampMs, String messageId, String replyToMid,
      {network_api.LinkPreviewRef? linkPreview,
      String? signature,
      String? publicKey}) {
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
      linkPreview: linkPreview,
      signature: signature,
      publicKey: publicKey,
    );
    _addMessage(serverId, channelId, msg);
    // No DB save here — Rust already persisted before emitting the event.
  }

  /// Hydrate signature, public key, and (critically) timestamp on an existing
  /// in-memory message. Called from the ChannelMessageSent event handler after
  /// Rust has signed+persisted the message — we overwrite the optimistic
  /// Dart-side `DateTime.now()` timestamp with Rust's exact value that the
  /// signature was actually computed over. Without the timestamp replacement,
  /// verification fails on machines with coarse OS timer resolution (e.g. VMs).
  void hydrateSignature(String serverId, String channelId, String messageId,
      int timestampMs, String? signature, String? publicKey) {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current == null) return;
    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;
    final updatedList = List<ChannelChatMessage>.from(current);
    updatedList[idx] = updatedList[idx].copyWith(
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      signature: signature,
      publicKey: publicKey,
    );
    final updated = Map.of(state);
    updated[key] = updatedList;
    state = updated;
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
  /// Updates signature + publicKey alongside text so the Message Proof dialog
  /// verifies against the edit's own signature, not the original's.
  void applyEdit(String serverId, String channelId, String messageId,
      String newText, int editedAtMs,
      {String? signature, String? publicKey}) {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current == null) return;

    final editedAt = DateTime.fromMillisecondsSinceEpoch(editedAtMs);
    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;

    final updatedList = List<ChannelChatMessage>.from(current);
    updatedList[idx] = updatedList[idx].copyWith(
      text: newText,
      editedAt: editedAt,
      signature: signature,
      publicKey: publicKey,
    );
    final updated = Map.of(state);
    updated[key] = updatedList;
    state = updated;
  }

  /// Attach (or clear) a link preview on a channel message we already sent
  /// (issue #45). Rethrows; the compose panes swallow it, since a late card
  /// that never lands is cosmetic.
  Future<void> attachLinkPreview(String serverId, String channelId,
      String messageId, network_api.LinkPreviewRef? preview) async {
    await network_api.attachChannelLinkPreview(
      serverId: serverId,
      channelId: channelId,
      messageId: messageId,
      preview: preview,
    );
    // UI update happens via the ChannelLinkPreviewUpdated event.
  }

  /// Apply a late link preview to an in-memory message. Never touches
  /// `editedAt` — see the DM twin in [ChatNotifier.applyLinkPreview].
  void applyLinkPreview(String serverId, String channelId, String messageId,
      network_api.LinkPreviewRef? preview) {
    final key = _key(serverId, channelId);
    final current = state[key];
    if (current == null) return;

    final idx = current.indexWhere((m) => m.messageId == messageId);
    if (idx == -1) return;
    if (current[idx].linkPreview == preview) return;

    final updatedList = List<ChannelChatMessage>.from(current);
    updatedList[idx] = updatedList[idx].copyWith(
      linkPreview: preview,
      clearLinkPreview: preview == null,
    );
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
    // Conference chat is RAM-only: nothing in the DB, no sync to request —
    // whatever is in memory IS the meeting's chat.
    if (serverId.startsWith('conf:')) return;
    // Always request sync from connected peers when opening a channel.
    // New messages arrive via MessageSyncCompleted → cache clear → reload.
    // .catchError, not try/catch: fire-and-forget — an async rejection (e.g.
    // "Node is not running" at startup) would escape a sync try/catch.
    network_api.requestChannelSync(
        serverId: serverId, channelId: channelId).catchError((_) {});

    try {
      final stored =
          await ref.read(storageServiceProvider).loadChannelMessages(
                serverId: serverId,
                channelId: channelId,
                limit: 200,
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
                  linkPreview: m.linkPreview,
                ))
            .toList();

        // DB is the source of truth, but preserve any in-memory messages
        // (by messageId) that aren't in the DB snapshot yet — covers the
        // tiny race where a message arrives mid-load, and keeps optimistic
        // in-flight sends that haven't round-tripped through Rust.
        final key = _key(serverId, channelId);
        final existing = state[key] ?? const <ChannelChatMessage>[];
        final loadedIds = messages
            .where((m) => m.messageId != null)
            .map((m) => m.messageId!)
            .toSet();
        final carryOver = existing
            .where((m) => m.messageId != null && !loadedIds.contains(m.messageId))
            .toList();
        // STABLE sort (index tie-break): same-millisecond messages must not
        // shuffle on reload — see _stableSortByTimestamp.
        final merged = _stableSortByTimestamp([...messages, ...carryOver]);
        final updated = Map.of(state);
        updated[key] = merged;
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

  /// Merge DB contents with in-memory messages for a channel.
  /// Unlike loadHistory(), this preserves live-delivered messages that
  /// arrived between sync completion and this reload — preventing data loss.
  Future<void> mergeFromDb(String serverId, String channelId) async {
    try {
      final stored =
          await ref.read(storageServiceProvider).loadChannelMessages(
                serverId: serverId,
                channelId: channelId,
                limit: 200,
              );

      final key = _key(serverId, channelId);
      final existing = state[key] ?? <ChannelChatMessage>[];

      // Build a set of message IDs from DB results for dedup.
      final dbMessageIds = <String>{};
      final dbMessages = <ChannelChatMessage>[];

      // Load reactions + file attachments for DB messages (same as loadHistory).
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
            );
          }
        } catch (_) {}
      }

      for (final m in stored) {
        if (m.messageId != null) {
          dbMessageIds.add(m.messageId!);
        }
        dbMessages.add(ChannelChatMessage(
          senderId: m.senderId,
          text: m.text,
          isMe: m.isMine,
          timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
          signature: m.signature,
          publicKey: m.publicKey,
          messageId: m.messageId,
          editedAt: m.editedAt != null
              ? DateTime.fromMillisecondsSinceEpoch(m.editedAt!)
              : null,
          replyToMid: m.replyToMid,
          reactions:
              m.messageId != null ? reactionsMap[m.messageId] : null,
          fileAttachment: m.fileId != null ? fileMap[m.fileId] : null,
          linkPreview: m.linkPreview,
        ));
      }

      // Merge: DB messages + any in-memory messages not in DB (live-delivered).
      final liveOnly = existing.where((m) =>
          m.messageId != null && !dbMessageIds.contains(m.messageId));
      // Stable sort by timestamp (newest last) and cap — same-millisecond
      // messages keep their DB (order_us) order.
      final merged = _stableSortByTimestamp([...dbMessages, ...liveOnly]);
      final capped = merged.length > _maxMessages
          ? merged.sublist(merged.length - _maxMessages)
          : merged;

      final updated = Map.of(state);
      updated[key] = capped;
      state = updated;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to merge channel history: $e');
    }
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
    String localPath, {
    String text = '',
  }) {
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    _addMessage(
      serverId,
      channelId,
      ChannelChatMessage(
        senderId: localPeerId,
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

  /// Max messages kept in memory per channel.
  static const _maxMessages = 200;

  void _addMessage(
      String serverId, String channelId, ChannelChatMessage message) {
    final key = _key(serverId, channelId);
    final current = state[key] ?? <ChannelChatMessage>[];
    // Plain append in ARRIVAL order — do NOT sort by sender wall-clock timestamp
    // (cross-machine clock skew would reorder the live conversation). Correct
    // ordering for synced/out-of-order arrivals comes from the loadHistory resort.
    var list = <ChannelChatMessage>[...current, message];
    // Trim oldest messages to prevent unbounded memory growth.
    if (list.length > _maxMessages) {
      list = list.sublist(list.length - _maxMessages);
    }
    final updated = Map.of(state);
    updated[key] = list;
    state = updated;
  }

  /// Request file downloads for messages near the viewport.
  final Set<String> _requestedFileIds = {};

  Future<void> requestVisibleFiles(
      String serverId, String channelId,
      List<ChannelChatMessage> messages,
      int firstVisible, int lastVisible) async {
    // Auto-download off for this server (#41): the viewport sweep IS the
    // auto-download for channel files — skip it; file cards offer a manual
    // Download button instead. VOICE NOTES stay exempt (they behave like
    // text), so the per-file loop below still pulls those.
    final gated = effectiveAutoDownloadMbRead(ref, 'server:$serverId') == 0;
    final start = (firstVisible - 15).clamp(0, messages.length - 1);
    final end = (lastVisible + 15).clamp(0, messages.length - 1);
    // Candidates come from THIS server's online members (master-keyed) —
    // never unrelated global peers, who don't hold channel files at all.
    final onlineMembers = ref.read(onlineMembersProvider(serverId));
    if (onlineMembers.isEmpty) return;
    final links = ref.read(deviceLinkProvider);
    final myMaster = ref.read(identityProvider).peerId;

    for (int i = start; i <= end; i++) {
      final msg = messages[i];
      final att = msg.fileAttachment;
      if (att == null || att.isComplete || att.diskPath != null) continue;
      if (gated && !isVoiceMessageFile(att.fileName)) continue;
      if (_requestedFileIds.contains(att.fileId)) continue;
      final transfer = ref.read(fileTransferProvider)[att.fileId];
      if (transfer != null && (transfer.isDownloading || transfer.isComplete)) continue;

      // Prefer the SENDER (most likely holder) when online, else any other
      // online member (sorted for determinism). ONE request only — Rust
      // reroutes an offline/failed target to another member, and multiple
      // parallel streams would poison the single FileHeader AES key.
      final senderMaster = links.identityOf(msg.senderId ?? '');
      final others = onlineMembers
          .where((m) => m != senderMaster && m != myMaster)
          .toList()
        ..sort();
      final candidates = [
        if (onlineMembers.contains(senderMaster)) senderMaster,
        ...others,
      ];
      if (candidates.isEmpty) continue; // no throttle — a later pass retries
      _requestedFileIds.add(att.fileId);
      for (final peerId in candidates) {
        try {
          await network_api.requestFileFromPeer(
              fileId: att.fileId, peerId: peerId, chunks: []);
          break;
        } catch (_) {}
      }
    }
  }

  /// Attach file metadata to an in-RAM row that has none yet. Guest live
  /// path: a public-channel file post's metadata arrives (FileHeaderReceived)
  /// right after the message row, which was stored without an attachment —
  /// without this the guest bubble renders the raw `[file:<id>]` token.
  /// No-op when the row is absent or already carries an attachment (member
  /// rows are rebuilt from the DB by `_reloadChatForFile` regardless).
  void attachFileMeta(String serverId, String channelId, String messageId,
      FileAttachment attachment) {
    final key = '$serverId:$channelId';
    final list = state[key];
    if (list == null) return;
    final idx = list.indexWhere((m) => m.messageId == messageId);
    if (idx < 0 || list[idx].fileAttachment != null) return;
    final updated = [...list];
    updated[idx] = list[idx].copyWith(fileAttachment: attachment);
    state = {...state, key: updated};
  }

  void setGuestMessages(String serverId, String channelId,
      List<ChannelChatMessage> messages) {
    final key = '$serverId:$channelId';
    final existing = state[key] ?? [];
    final existingIds =
        existing.map((m) => m.messageId).whereType<String>().toSet();
    final newMsgs = messages
        .where(
            (m) => m.messageId == null || !existingIds.contains(m.messageId))
        .toList();
    final merged = _stableSortByTimestamp([...existing, ...newMsgs]);
    state = {...state, key: merged};
  }

  void clearGuestServer(String serverId) {
    final updated = Map.of(state);
    updated.removeWhere((key, _) => key.startsWith('$serverId:'));
    state = updated;
  }

  void clearGuestChannel(String serverId, String channelId) {
    final key = '$serverId:$channelId';
    if (!state.containsKey(key)) return;
    final updated = Map.of(state);
    updated.remove(key);
    state = updated;
  }
}

/// Sort by timestamp with the ORIGINAL index as tie-break — a stable sort.
/// `List.sort` is unstable: messages sharing a millisecond (fast spam) would
/// otherwise swap randomly on every history merge.
List<ChannelChatMessage> _stableSortByTimestamp(List<ChannelChatMessage> list) {
  final entries = list.asMap().entries.toList()
    ..sort((a, b) {
      final c = a.value.timestamp.compareTo(b.value.timestamp);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return [for (final e in entries) e.value];
}

final channelChatProvider = NotifierProvider<ChannelChatNotifier,
    Map<String, List<ChannelChatMessage>>>(ChannelChatNotifier.new);

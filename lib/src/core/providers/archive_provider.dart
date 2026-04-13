import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Controls whether the Archive tab is open (replaces main content area).
final archiveTabOpenProvider = StateProvider<bool>((ref) => false);

/// Which top-level tab is active.
enum ArchiveSubTab { myData, importedArchives }

final archiveSubTabProvider =
    StateProvider<ArchiveSubTab>((ref) => ArchiveSubTab.myData);

/// Which inner tab is active in "My Data".
enum MyDataInnerTab { dms, channels }

final myDataInnerTabProvider =
    StateProvider<MyDataInnerTab>((ref) => MyDataInnerTab.dms);

/// Currently selected DM peer in the archive viewer.
final archiveSelectedDmProvider = StateProvider<String?>((ref) => null);

/// Currently selected channel ("serverId:channelId" composite key).
final archiveSelectedChannelProvider = StateProvider<String?>((ref) => null);

/// Search query for filtering the conversation list.
final archiveSearchProvider = StateProvider<String>((ref) => '');

/// Selected sender ID for filtering channel messages in archive (null = show all).
final archiveFilterSenderProvider = StateProvider<String?>((ref) => null);

/// Whether the in-message search bar is open in the archive viewer.
final archiveMessageSearchOpenProvider = StateProvider<bool>((ref) => false);

/// The current in-message search query text.
final archiveMessageSearchQueryProvider = StateProvider<String>((ref) => '');

/// Current match index (0-based) for navigating between search results.
final archiveSearchMatchIndexProvider = StateProvider<int>((ref) => 0);

/// Target date for jump-to-date in archive viewers (null = no jump pending).
final archiveJumpToDateProvider = StateProvider<DateTime?>((ref) => null);

/// Selected channel within an imported server archive (null = first channel).
final importedArchiveSelectedChannelProvider = StateProvider<String?>((ref) => null);

// ── Edit history for My Data archive viewers ───────────────────

/// A single edit history entry.
class ArchiveEditEntry {
  final String messageId;
  final String oldText;
  final String newText;
  final DateTime editedAt;
  final String? signature;
  final String? publicKey;

  const ArchiveEditEntry({
    required this.messageId,
    required this.oldText,
    required this.newText,
    required this.editedAt,
    this.signature,
    this.publicKey,
  });
}

/// Loads edit history for a DM conversation (keyed by peerId).
/// Returns a map of messageId -> list of edits.
final archiveDmEditsProvider = FutureProvider.autoDispose
    .family<Map<String, List<ArchiveEditEntry>>, String>((ref, peerId) async {
  final messages = await storage_api.loadAllDmMessages(peerId: peerId);
  final editedIds = messages
      .where((m) => m.messageId != null && m.editedAt != null)
      .map((m) => m.messageId!)
      .toList();
  if (editedIds.isEmpty) return {};
  final edits = await storage_api.loadMessageEdits(messageIds: editedIds);
  final map = <String, List<ArchiveEditEntry>>{};
  for (final e in edits) {
    map.putIfAbsent(e.messageId, () => []).add(ArchiveEditEntry(
      messageId: e.messageId,
      oldText: e.oldText,
      newText: e.newText,
      editedAt: DateTime.fromMillisecondsSinceEpoch(e.editedAt),
      signature: e.signature,
      publicKey: e.publicKey,
    ));
  }
  return map;
});

/// Loads edit history for a channel conversation (keyed by "serverId:channelId").
final archiveChannelEditsProvider = FutureProvider.autoDispose
    .family<Map<String, List<ArchiveEditEntry>>, String>((ref, key) async {
  final parts = key.split(':');
  if (parts.length < 2) return {};
  final serverId = parts[0];
  final channelId = parts.sublist(1).join(':');
  final messages = await storage_api.loadAllChannelMessages(
    serverId: serverId, channelId: channelId);
  final editedIds = messages
      .where((m) => m.messageId != null && m.editedAt != null)
      .map((m) => m.messageId!)
      .toList();
  if (editedIds.isEmpty) return {};
  final edits = await storage_api.loadMessageEdits(messageIds: editedIds);
  final map = <String, List<ArchiveEditEntry>>{};
  for (final e in edits) {
    map.putIfAbsent(e.messageId, () => []).add(ArchiveEditEntry(
      messageId: e.messageId,
      oldText: e.oldText,
      newText: e.newText,
      editedAt: DateTime.fromMillisecondsSinceEpoch(e.editedAt),
      signature: e.signature,
      publicKey: e.publicKey,
    ));
  }
  return map;
});

// ── Conversation list providers ─────────────────────────────────

/// All DM peers with message counts.
final archiveDmListProvider =
    FutureProvider<List<ArchiveDmEntry>>((ref) async {
  final peerIds = await storage_api.getDmPeerIds();
  final entries = <ArchiveDmEntry>[];
  for (final pid in peerIds) {
    final count = await storage_api.countDmMessages(peerId: pid);
    if (count > 0) {
      entries.add(ArchiveDmEntry(peerId: pid, messageCount: count));
    }
  }
  // Sort by message count descending (most active first).
  entries.sort((a, b) => b.messageCount.compareTo(a.messageCount));
  return entries;
});

/// All servers with their channels that have message history.
final archiveChannelListProvider =
    FutureProvider<List<ArchiveChannelGroup>>((ref) async {
  final servers = await crdt_api.getJoinedServers();
  final groups = <ArchiveChannelGroup>[];
  for (final server in servers) {
    final channels =
        await crdt_api.getServerChannels(serverId: server.serverId);
    final entries = <ArchiveChannelEntry>[];
    for (final ch in channels) {
      if (ch.channelType == 'voice') continue;
      final count = await storage_api.countChannelMessagesFfi(
        serverId: server.serverId,
        channelId: ch.channelId,
      );
      if (count == 0) continue;
      entries.add(ArchiveChannelEntry(
        serverId: server.serverId,
        serverName: server.name,
        channelId: ch.channelId,
        channelName: ch.name,
        messageCount: count,
      ));
    }
    if (entries.isNotEmpty) {
      groups.add(ArchiveChannelGroup(
        serverId: server.serverId,
        serverName: server.name,
        channels: entries,
      ));
    }
  }
  return groups;
});

// ── Message loading providers ───────────────────────────────────

/// Load all DM messages for a peer (including deleted). Auto-disposes on key change.
final archiveDmMessagesProvider = FutureProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, peerId) async {
  final stored = await storage_api.loadAllDmMessages(peerId: peerId);

  // Bulk-load reactions.
  final messageIds = stored
      .where((m) => m.messageId != null)
      .map((m) => m.messageId!)
      .toList();
  final reactionsMap = <String, Map<String, List<String>>>{};
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

  // Bulk-load file attachments.
  final fileIds =
      stored.where((m) => m.fileId != null).map((m) => m.fileId!).toSet();
  final fileMap = <String, FileAttachment>{};
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
        );
      }
    } catch (_) {}
  }

  return stored
      .map((m) => ChatMessage(
            text: m.text,
            isMe: m.isMine,
            timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
            signature: m.signature,
            publicKey: m.publicKey,
            messageId: m.messageId,
            editedAt: m.editedAt != null
                ? DateTime.fromMillisecondsSinceEpoch(m.editedAt!)
                : null,
            hiddenAt: m.hiddenAt != null
                ? DateTime.fromMillisecondsSinceEpoch(m.hiddenAt!)
                : null,
            replyToMid: m.replyToMid,
            reactions:
                m.messageId != null ? reactionsMap[m.messageId] : null,
            fileAttachment: m.fileId != null ? fileMap[m.fileId] : null,
            linkPreview: m.linkPreview,
          ))
      .toList();
});

/// Load all channel messages (including deleted). Auto-disposes on key change.
/// Key format: "serverId:channelId".
final archiveChannelMessagesProvider = FutureProvider.autoDispose
    .family<List<ChannelChatMessage>, String>((ref, key) async {
  final parts = key.split(':');
  if (parts.length < 2) return [];
  final serverId = parts[0];
  final channelId = parts.sublist(1).join(':');

  final stored = await storage_api.loadAllChannelMessages(
    serverId: serverId,
    channelId: channelId,
  );

  // Bulk-load reactions.
  final messageIds = stored
      .where((m) => m.messageId != null)
      .map((m) => m.messageId!)
      .toList();
  final reactionsMap = <String, Map<String, List<String>>>{};
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

  // Bulk-load file attachments.
  final fileIds =
      stored.where((m) => m.fileId != null).map((m) => m.fileId!).toSet();
  final fileMap = <String, FileAttachment>{};
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
        );
      }
    } catch (_) {}
  }

  return stored
      .map((m) => ChannelChatMessage(
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
            hiddenAt: m.hiddenAt != null
                ? DateTime.fromMillisecondsSinceEpoch(m.hiddenAt!)
                : null,
            replyToMid: m.replyToMid,
            reactions:
                m.messageId != null ? reactionsMap[m.messageId] : null,
            fileAttachment: m.fileId != null ? fileMap[m.fileId] : null,
            linkPreview: m.linkPreview,
          ))
      .toList();
});

// ── Imported Archives providers ─────────────────────────────────

/// Selected imported archive file path.
final selectedImportedArchiveProvider = StateProvider<String?>((ref) => null);

/// Persisted list of imported .hollow-archive file paths.
final importedArchivePathsProvider =
    AsyncNotifierProvider<ImportedArchivePathsNotifier, List<String>>(
        ImportedArchivePathsNotifier.new);

class ImportedArchivePathsNotifier extends AsyncNotifier<List<String>> {
  static const _settingsKey = 'imported_archive_paths';

  @override
  Future<List<String>> build() async {
    final raw = await storage_api.loadSetting(key: _settingsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final paths = (jsonDecode(raw) as List).cast<String>();
      final valid = paths.where((p) => File(p).existsSync()).toList();
      if (valid.length != paths.length) {
        await storage_api.saveSetting(
            key: _settingsKey, value: jsonEncode(valid));
      }
      return valid;
    } catch (_) {
      return [];
    }
  }

  Future<void> addPath(String path) async {
    final current = state.valueOrNull ?? [];
    if (current.contains(path)) return;
    final updated = [...current, path];
    await storage_api.saveSetting(
        key: _settingsKey, value: jsonEncode(updated));
    state = AsyncData(updated);
  }

  Future<void> removePath(String path) async {
    final current = state.valueOrNull ?? [];
    final updated = current.where((p) => p != path).toList();
    await storage_api.saveSetting(
        key: _settingsKey, value: jsonEncode(updated));
    state = AsyncData(updated);
    if (ref.read(selectedImportedArchiveProvider) == path) {
      ref.read(selectedImportedArchiveProvider.notifier).state = null;
    }
  }
}

/// Quick-verify an imported archive (manifest + signatures only).
final importedArchiveVerifyProvider =
    FutureProvider.family<archive_api.ArchiveVerifyResult, String>(
        (ref, path) async {
  return await archive_api.verifyArchive(archivePath: path);
});

/// Full-load an imported archive. Auto-disposes when user navigates away.
final importedArchiveDataProvider =
    FutureProvider.autoDispose.family<archive_api.ArchiveData, String>(
        (ref, path) async {
  return await archive_api.loadArchive(archivePath: path);
});

// ── Conversion: ArchiveMessageFfi → ChatMessage / ChannelChatMessage ──

List<ChatMessage> convertArchiveDmMessages(
    archive_api.ArchiveData data, String localPeerId) {
  final fileMap = {for (final f in data.files) f.fileId: f};
  return data.messages.map((m) {
    final reactions = <String, List<String>>{};
    for (final r in m.reactions) {
      reactions.putIfAbsent(r.emoji, () => []).add(r.peerId);
    }
    FileAttachment? fileAttachment;
    if (m.fileId != null && fileMap.containsKey(m.fileId)) {
      final f = fileMap[m.fileId]!;
      String? diskPath;
      if (f.included && data.filesDir != null) {
        diskPath = '${data.filesDir}/${f.fileId}.${f.fileExt}';
      }
      fileAttachment = FileAttachment(
        fileId: f.fileId, fileName: f.fileName, fileExt: f.fileExt,
        mimeType: f.mimeType, sizeBytes: f.sizeBytes.toInt(),
        isImage: f.isImage, width: f.width, height: f.height,
        totalChunks: 1, chunksReceived: f.included ? 1 : 0,
        isComplete: f.included, diskPath: diskPath,
      );
    }
    return ChatMessage(
      text: m.text, isMe: m.senderId == localPeerId,
      timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
      signature: m.signature, publicKey: m.publicKey, messageId: m.messageId,
      editedAt: m.editedAt != null ? DateTime.fromMillisecondsSinceEpoch(m.editedAt!) : null,
      hiddenAt: m.hiddenAt != null ? DateTime.fromMillisecondsSinceEpoch(m.hiddenAt!) : null,
      replyToMid: m.replyToMid,
      reactions: reactions.isNotEmpty ? reactions : null,
      fileAttachment: fileAttachment,
    );
  }).toList();
}

List<ChannelChatMessage> convertArchiveChannelMessages(
    archive_api.ArchiveData data, String localPeerId) {
  final fileMap = {for (final f in data.files) f.fileId: f};
  return data.messages.map((m) {
    final reactions = <String, List<String>>{};
    for (final r in m.reactions) {
      reactions.putIfAbsent(r.emoji, () => []).add(r.peerId);
    }
    FileAttachment? fileAttachment;
    if (m.fileId != null && fileMap.containsKey(m.fileId)) {
      final f = fileMap[m.fileId]!;
      String? diskPath;
      if (f.included && data.filesDir != null) {
        diskPath = '${data.filesDir}/${f.fileId}.${f.fileExt}';
      }
      fileAttachment = FileAttachment(
        fileId: f.fileId, fileName: f.fileName, fileExt: f.fileExt,
        mimeType: f.mimeType, sizeBytes: f.sizeBytes.toInt(),
        isImage: f.isImage, width: f.width, height: f.height,
        totalChunks: 1, chunksReceived: f.included ? 1 : 0,
        isComplete: f.included, diskPath: diskPath,
      );
    }
    return ChannelChatMessage(
      senderId: m.senderId, text: m.text, isMe: m.senderId == localPeerId,
      timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp),
      signature: m.signature, publicKey: m.publicKey, messageId: m.messageId,
      editedAt: m.editedAt != null ? DateTime.fromMillisecondsSinceEpoch(m.editedAt!) : null,
      hiddenAt: m.hiddenAt != null ? DateTime.fromMillisecondsSinceEpoch(m.hiddenAt!) : null,
      replyToMid: m.replyToMid,
      reactions: reactions.isNotEmpty ? reactions : null,
      fileAttachment: fileAttachment,
    );
  }).toList();
}

import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/archive_provider.dart'
    show
        ArchiveEditEntry,
        convertArchiveChannelMessages,
        convertArchiveDmMessages;
import 'package:hollow/src/rust/api/archive.dart' as archive_api;

/// All derived state for the imported-archive viewers, as pure data: both call
/// [prepareImportedArchive] and only render the result.
class ImportedArchivePrep {
  final bool isDm;
  final bool isServer;
  /// Server archives: the currently selected channel.
  final String? activeChannelId;
  final String? activeChannelName;
  /// DM archives only.
  final List<ChatMessage>? dmMessages;
  /// Channel/server archives: sender-filtered visible messages.
  final List<ChannelChatMessage>? channelMessages;
  /// Channel/server archives: channel-filtered but NOT sender-filtered
  /// (reply lookups + filter totals).
  final List<ChannelChatMessage>? unfilteredChannelMessages;
  final List<String>? uniqueSenders;
  final Map<String, String> senderNames;
  final Map<String, dynamic> senderAvatars;
  final Map<String, List<ArchiveEditEntry>> editsMap;
  final String proofContext;
  final String proofMsgType;
  final String headerTitle;
  final String? headerSubtitle;
  // Tone booleans; the widget maps them to a colour and an icon.
  final bool archiveSigValid;
  final String archiveSigText;
  final bool msgSigWarning;
  final String msgSigText;

  const ImportedArchivePrep({
    required this.isDm,
    required this.isServer,
    required this.activeChannelId,
    required this.activeChannelName,
    required this.dmMessages,
    required this.channelMessages,
    required this.unfilteredChannelMessages,
    required this.uniqueSenders,
    required this.senderNames,
    required this.senderAvatars,
    required this.editsMap,
    required this.proofContext,
    required this.proofMsgType,
    required this.headerTitle,
    required this.headerSubtitle,
    required this.archiveSigValid,
    required this.archiveSigText,
    required this.msgSigWarning,
    required this.msgSigText,
  });
}

/// Converts and filters an imported archive into everything the viewers render.
/// [avatarOf] is desktop-only and omitted on mobile.
ImportedArchivePrep prepareImportedArchive({
  required archive_api.ArchiveData data,
  required String localPeerId,
  required String? filterSender,
  required String? selectedChannelId,
  required String Function(String peerId) displayNameOf,
  dynamic Function(String peerId)? avatarOf,
}) {
  final v = data.verification;
  final isDm = data.archiveType == 'dm';
  final isServer = data.archiveType == 'server';

  final dateStr = calendarDateLabel(
      DateTime.fromMillisecondsSinceEpoch(v.exportTimestamp));
  final exporterName = displayNameOf(v.exporterPeerId);

  final archiveSigValid = v.archiveSignatureValid;
  final archiveSigText = archiveSigValid
      ? 'Signed by $exporterName on $dateStr'
      : "The archive's signature doesn't match, so it may have been changed";

  final msgSigWarning = v.messagesWithInvalidSig > 0;
  final String msgSigText;
  if (msgSigWarning) {
    msgSigText = '${v.messagesWithInvalidSig} of ${v.messageCount} messages '
        'failed their signature check';
  } else if (v.messagesWithValidSig > 0) {
    msgSigText = v.messagesWithValidSig == 1
        ? '1 message verified from its sender'
        : '${v.messagesWithValidSig} messages verified from their senders';
  } else {
    msgSigText = '${v.messageCount} messages, none of them signed';
  }

  String? activeChannelId;
  String? activeChannelName;
  if (isServer && data.channels.isNotEmpty) {
    activeChannelId = selectedChannelId ?? data.channels.first.channelId;
    activeChannelName = data.channels
            .where((c) => c.channelId == activeChannelId)
            .firstOrNull
            ?.channelName ??
        activeChannelId;
  }

  List<ChatMessage>? dmMessages;
  List<ChannelChatMessage>? channelMessages;

  if (isDm) {
    dmMessages = convertArchiveDmMessages(data, localPeerId);
  } else {
    final allChannelMessages = convertArchiveChannelMessages(data, localPeerId);
    if (isServer && activeChannelId != null) {
      final channelMsgIds = <String>{};
      for (final m in data.messages) {
        if (m.channelId == activeChannelId) {
          channelMsgIds.add(m.messageId);
        }
      }
      channelMessages = allChannelMessages
          .where((m) => channelMsgIds.contains(m.messageId))
          .toList();
    } else {
      channelMessages = allChannelMessages;
    }
  }

  final unfilteredChannelMessages = channelMessages;
  if (filterSender != null && channelMessages != null) {
    channelMessages =
        channelMessages.where((m) => m.senderId == filterSender).toList();
  }

  final uniqueSenders =
      unfilteredChannelMessages?.map((m) => m.senderId).toSet().toList()
        ?..sort();
  final senderNames = uniqueSenders != null
      ? {for (final id in uniqueSenders) id: displayNameOf(id)}
      : <String, String>{};
  final senderAvatars = uniqueSenders != null && avatarOf != null
      ? <String, dynamic>{for (final id in uniqueSenders) id: avatarOf(id)}
      : <String, dynamic>{};

  final editsMap = <String, List<ArchiveEditEntry>>{};
  for (final e in data.edits) {
    editsMap.putIfAbsent(e.messageId, () => []).add(ArchiveEditEntry(
          messageId: e.messageId,
          oldText: e.oldText,
          newText: e.newText,
          editedAt: DateTime.fromMillisecondsSinceEpoch(e.editedAt),
          signature: e.signature,
          publicKey: e.publicKey,
          prevSignature: e.prevSignature,
          prevPublicKey: e.prevPublicKey,
          prevTimestampMs: e.prevTimestamp,
        ));
  }

  final proofContext = isDm
      ? (data.peerId ?? '')
      : '${data.serverId ?? ''}:${activeChannelId ?? data.channelId ?? ''}';
  final proofMsgType = isDm ? 'dm' : 'ch';

  String headerTitle;
  String? headerSubtitle;
  if (isDm) {
    headerTitle = displayNameOf(data.peerId ?? '');
  } else if (isServer) {
    headerTitle = activeChannelName ?? 'Channel';
    headerSubtitle = data.serverName ?? 'Server';
  } else {
    headerTitle = data.channelName ?? 'Channel';
    headerSubtitle = data.serverName;
  }

  return ImportedArchivePrep(
    isDm: isDm,
    isServer: isServer,
    activeChannelId: activeChannelId,
    activeChannelName: activeChannelName,
    dmMessages: dmMessages,
    channelMessages: channelMessages,
    unfilteredChannelMessages: unfilteredChannelMessages,
    uniqueSenders: uniqueSenders,
    senderNames: senderNames,
    senderAvatars: senderAvatars,
    editsMap: editsMap,
    proofContext: proofContext,
    proofMsgType: proofMsgType,
    headerTitle: headerTitle,
    headerSubtitle: headerSubtitle,
    archiveSigValid: archiveSigValid,
    archiveSigText: archiveSigText,
    msgSigWarning: msgSigWarning,
    msgSigText: msgSigText,
  );
}

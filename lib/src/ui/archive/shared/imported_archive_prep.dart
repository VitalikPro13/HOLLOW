import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/archive_provider.dart'
    show
        ArchiveEditEntry,
        convertArchiveChannelMessages,
        convertArchiveDmMessages;
import 'package:hollow/src/rust/api/archive.dart' as archive_api;

/// All derived state for the imported-archive viewers (desktop + mobile).
/// Pure data — no widgets, no Riverpod. Both viewers call
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
  // Verification banner. Tone booleans map to color/icon in the widget.
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

/// Converts + filters an imported archive into everything the viewers render.
/// [mobile] keeps each form factor's existing wording (banner strings).
/// [avatarOf] is desktop-only (filter dropdown avatars); omit on mobile.
ImportedArchivePrep prepareImportedArchive({
  required archive_api.ArchiveData data,
  required String localPeerId,
  required String? filterSender,
  required String? selectedChannelId,
  required String Function(String peerId) displayNameOf,
  dynamic Function(String peerId)? avatarOf,
  required bool mobile,
}) {
  final v = data.verification;
  final isDm = data.archiveType == 'dm';
  final isServer = data.archiveType == 'server';

  // Verification banner data.
  final exportDate = DateTime.fromMillisecondsSinceEpoch(v.exportTimestamp);
  final dateStr =
      '${exportDate.year}-${exportDate.month.toString().padLeft(2, '0')}-${exportDate.day.toString().padLeft(2, '0')}';
  final exporterName = displayNameOf(v.exporterPeerId);

  // Archive-level signature (file integrity).
  final archiveSigValid = v.archiveSignatureValid;
  final String archiveSigText;
  if (archiveSigValid) {
    archiveSigText = mobile
        ? 'Signed by $exporterName on $dateStr'
        : 'Archive signed by $exporterName on $dateStr';
  } else {
    archiveSigText = mobile
        ? 'Signature invalid: may be tampered'
        : 'Archive signature invalid: may have been tampered with';
  }

  // Per-message signatures.
  final msgSigWarning = v.messagesWithInvalidSig > 0;
  final String msgSigText;
  if (msgSigWarning) {
    msgSigText = mobile
        ? '${v.messagesWithInvalidSig}/${v.messageCount} messages failed verification'
        : '${v.messagesWithInvalidSig} of ${v.messageCount} messages failed signature verification';
  } else if (v.messagesWithValidSig > 0) {
    msgSigText = mobile
        ? '${v.messagesWithValidSig} messages verified'
        : '${v.messagesWithValidSig} messages verified from original senders';
  } else {
    msgSigText = '${v.messageCount} messages (no signatures)';
  }

  // For server archives, handle channel selection.
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

  // Convert archive messages (filter by channel for server archives).
  List<ChatMessage>? dmMessages;
  List<ChannelChatMessage>? channelMessages;

  if (isDm) {
    dmMessages = convertArchiveDmMessages(data, localPeerId);
  } else {
    final allChannelMessages = convertArchiveChannelMessages(data, localPeerId);
    if (isServer && activeChannelId != null) {
      // Filter messages by selected channel using the raw FFI data's channel_id.
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

  // Apply sender filter (capture the pre-filter list first).
  final unfilteredChannelMessages = channelMessages;
  if (filterSender != null && channelMessages != null) {
    channelMessages =
        channelMessages.where((m) => m.senderId == filterSender).toList();
  }

  // Collect unique senders for filter (channel archives only).
  final uniqueSenders =
      unfilteredChannelMessages?.map((m) => m.senderId).toSet().toList()
        ?..sort();
  final senderNames = uniqueSenders != null
      ? {for (final id in uniqueSenders) id: displayNameOf(id)}
      : <String, String>{};
  final senderAvatars = uniqueSenders != null && avatarOf != null
      ? <String, dynamic>{for (final id in uniqueSenders) id: avatarOf(id)}
      : <String, dynamic>{};

  // Build edits map from archive data.
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

  // Context for Message Proof.
  final proofContext = isDm
      ? (data.peerId ?? '')
      : '${data.serverId ?? ''}:${activeChannelId ?? data.channelId ?? ''}';
  final proofMsgType = isDm ? 'dm' : 'ch';

  // Header title/subtitle.
  String headerTitle;
  String? headerSubtitle;
  if (isDm) {
    headerTitle = displayNameOf(data.peerId ?? '');
  } else if (isServer) {
    headerTitle = activeChannelName ?? 'Channel';
    headerSubtitle = 'in ${data.serverName ?? 'Server'}';
  } else {
    headerTitle = data.channelName ?? 'Channel';
    headerSubtitle = data.serverName != null ? 'in ${data.serverName}' : null;
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/archive/archive_message_viewer.dart'
    show archiveLoadError, jumpToArchiveDate, toggleArchiveSearch;
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_sender_filter.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/long_press_message.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/media/media_viewer_scope.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_message_actions.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The time a message was sent, for the long-press sheet: `14:05` today, a
/// day in words before it.
String archiveMessageTimeLabel(DateTime at) {
  final clock =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  final now = DateTime.now();
  final today = at.year == now.year && at.month == now.month && at.day == now.day;
  return today ? clock : '${calendarDateLabel(at, now: now)}, $clock';
}

/// Reading back one conversation from Messages on a phone. The tab resets the
/// viewer's search and filter when this route closes.
class MobileArchiveViewerRoute extends ConsumerStatefulWidget {
  final String? peerId;
  final String? serverId;
  final String? channelId;

  const MobileArchiveViewerRoute({
    super.key,
    this.peerId,
    this.serverId,
    this.channelId,
  });

  bool get isDm => peerId != null;

  @override
  ConsumerState<MobileArchiveViewerRoute> createState() =>
      _MobileArchiveViewerRouteState();
}

class _MobileArchiveViewerRouteState
    extends ConsumerState<MobileArchiveViewerRoute> {
  final _listController = ArchiveMessageListController();

  Duration _scrollDuration() => ReduceMotionController.instance.isReduced
      ? Duration.zero
      : const Duration(milliseconds: 300);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: widget.isDm ? _dmViewer() : _channelViewer(hollow),
      ),
    );
  }

  Widget _dmViewer() {
    final peerId = widget.peerId!;
    final messagesAsync = ref.watch(archiveDmMessagesProvider(peerId));
    final isSaved = peerId == ref.watch(savedMessagesPeerIdProvider);
    final peerProfile = ref.watch(profileProvider.select((p) => p[peerId]));
    final displayName =
        isSaved ? 'Saved messages' : displayNameForPeer(peerProfile, peerId);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final allMessages = messagesAsync.valueOrNull ?? const <ChatMessage>[];

    return Column(
      children: [
        ArchiveMobileToolbar(
          leading: isSaved
              ? const SavedMessagesAvatar(size: 28)
              : HollowAvatar(peerId: peerId, size: 28),
          title: displayName,
          subtitle: messagesAsync.hasValue
              ? archiveCountLabel(allMessages.length)
              : null,
          searchOpen: searchOpen,
          onBack: () => Navigator.pop(context),
          onToggleSearch: () => toggleArchiveSearch(ref),
          onJumpToDate: allMessages.isNotEmpty
              ? () => jumpToArchiveDate(
                  context, ref, [for (final m in allMessages) m.timestamp])
              : null,
          onExport: () => showExportArchiveDialog(
            context,
            isDm: true,
            peerId: peerId,
            name: displayName,
            messageCount: allMessages.length,
          ),
        ),
        if (searchOpen)
          ArchiveListSearchBar(
            texts: [for (final m in allMessages) m.text],
            controller: _listController,
          ),
        Expanded(
          child: messagesAsync.when(
            loading: () => const Center(child: HollowSpinner.large()),
            error: (_, _) => archiveLoadError(
                () => ref.invalidate(archiveDmMessagesProvider(peerId))),
            data: (messages) => _dmList(messages, peerId),
          ),
        ),
      ],
    );
  }

  Widget _dmList(List<ChatMessage> messages, String peerId) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final editsMap =
        ref.watch(archiveDmEditsProvider(peerId)).valueOrNull ?? {};

    return MediaViewerScope(
      // Read-only: an archived file can be saved and nothing else.
      actions: MediaViewerActions(
          onSaveAs: (a) => saveArchivedAttachmentMobile(context, a)),
      child: ArchiveDmMessageList(
        messages: messages,
        peerId: peerId,
        localPeerId: localPeerId,
        editsMap: editsMap,
        proofContextFor: (msg) => msg.isMe ? peerId : localPeerId,
        proofMsgType: 'dm',
        controller: _listController,
        scrollDuration: _scrollDuration,
        actionWrapper: (context, msg, child) => LongPressMessage(
          onLongPress: () {
            final sender = msg.isMe ? localPeerId : peerId;
            _showActions(
              text: msg.text,
              timestamp: msg.timestamp,
              senderPeerId: sender,
              attachment: msg.fileAttachment,
              proof: msg.messageId == null
                  ? null
                  : (profiles) => MessageProofData(
                        senderPeerId: sender,
                        senderDisplayName: displayNameFor(profiles, sender),
                        text: msg.text,
                        timestampMs: (msg.editedAt ?? msg.timestamp)
                            .millisecondsSinceEpoch,
                        signature: msg.signature,
                        publicKey: msg.publicKey,
                        messageId: msg.messageId,
                        context: msg.isMe ? peerId : localPeerId,
                        msgType: 'dm',
                        fileAttachment: msg.fileAttachment,
                        preverified: msg.archiveSignatureValid,
                      ),
            );
          },
          child: child,
        ),
      ),
    );
  }

  Widget _channelViewer(HollowTheme hollow) {
    final serverId = widget.serverId!;
    final channelId = widget.channelId!;
    final key = '$serverId:$channelId';
    final messagesAsync = ref.watch(archiveChannelMessagesProvider(key));
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);

    var channelName = channelId;
    var serverName = serverId;
    for (final group in ref.watch(archiveChannelListProvider).valueOrNull ??
        const <ArchiveChannelGroup>[]) {
      for (final ch in group.channels) {
        if (ch.serverId == serverId && ch.channelId == channelId) {
          channelName = ch.channelName;
          serverName = ch.serverName;
        }
      }
    }

    final allMessages =
        messagesAsync.valueOrNull ?? const <ChannelChatMessage>[];
    final uniqueSenders =
        allMessages.map((m) => m.senderId).toSet().toList()..sort();
    final profiles = ref.watch(profileProvider);
    final filtered = filterSender == null
        ? allMessages
        : allMessages.where((m) => m.senderId == filterSender).toList();

    return Column(
      children: [
        ArchiveMobileToolbar(
          leading:
              Icon(LucideIcons.hash, size: 20, color: hollow.textSecondary),
          title: channelName,
          subtitle: serverName,
          searchOpen: searchOpen,
          onBack: () => Navigator.pop(context),
          onToggleSearch: () => toggleArchiveSearch(ref),
          onFilter: uniqueSenders.length > 1
              ? () => showArchiveFilterSheet(
                    context,
                    senderIds: uniqueSenders,
                    selectedSender: filterSender,
                    senderNames: {
                      for (final id in uniqueSenders)
                        id: displayNameFor(profiles, id),
                    },
                    onSelected: _setSender,
                  )
              : null,
          filterActive: filterSender != null,
          onJumpToDate: filtered.isNotEmpty
              ? () => jumpToArchiveDate(
                  context, ref, [for (final m in filtered) m.timestamp])
              : null,
          onExport: () => showExportArchiveDialog(
            context,
            isDm: false,
            serverId: serverId,
            channelId: channelId,
            channelName: channelName,
            name: channelName,
            messageCount: allMessages.length,
          ),
        ),
        if (searchOpen)
          ArchiveListSearchBar(
            texts: [for (final m in filtered) m.text],
            controller: _listController,
          ),
        Expanded(
          child: messagesAsync.when(
            loading: () => const Center(child: HollowSpinner.large()),
            error: (_, _) => archiveLoadError(
                () => ref.invalidate(archiveChannelMessagesProvider(key))),
            data: (_) => _channelList(filtered, allMessages, serverId, key),
          ),
        ),
      ],
    );
  }

  Widget _channelList(
    List<ChannelChatMessage> messages,
    List<ChannelChatMessage> allMessages,
    String serverId,
    String proofContext,
  ) {
    final editsMap =
        ref.watch(archiveChannelEditsProvider(proofContext)).valueOrNull ?? {};

    return MediaViewerScope(
      // Read-only: an archived file can be saved and nothing else.
      actions: MediaViewerActions(
          onSaveAs: (a) => saveArchivedAttachmentMobile(context, a)),
      child: ArchiveChannelMessageList(
        messages: messages,
        allMessages: allMessages,
        serverId: serverId,
        editsMap: editsMap,
        proofContext: proofContext,
        proofMsgType: 'ch',
        controller: _listController,
        scrollDuration: _scrollDuration,
        actionWrapper: (context, msg, child) => LongPressMessage(
          onLongPress: () => _showActions(
            text: msg.text,
            timestamp: msg.timestamp,
            senderPeerId: msg.senderId,
            attachment: msg.fileAttachment,
            proof: msg.messageId == null
                ? null
                : (profiles) => MessageProofData(
                      senderPeerId: msg.senderId,
                      senderDisplayName:
                          displayNameFor(profiles, msg.senderId),
                      text: msg.text,
                      timestampMs: (msg.editedAt ?? msg.timestamp)
                          .millisecondsSinceEpoch,
                      signature: msg.signature,
                      publicKey: msg.publicKey,
                      messageId: msg.messageId,
                      context: proofContext,
                      msgType: 'ch',
                      fileAttachment: msg.fileAttachment,
                      preverified: msg.archiveSignatureValid,
                    ),
          ),
          child: child,
        ),
      ),
    );
  }

  void _setSender(String? sender) {
    ref.read(archiveFilterSenderProvider.notifier).state = sender;
    ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
    ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
  }

  void _showActions({
    required String text,
    required DateTime timestamp,
    required String senderPeerId,
    required FileAttachment? attachment,
    required MessageProofData Function(
            Map<String, storage_api.UserProfile> profiles)?
        proof,
  }) {
    final profiles = ref.read(profileProvider);
    showMobileArchiveMessageActions(
      context: context,
      messageText: messagePreviewText(text, attachment: attachment),
      senderName: displayNameFor(profiles, senderPeerId),
      timestamp: archiveMessageTimeLabel(timestamp),
      onCopy: text.isNotEmpty && !text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: attachment?.diskPath != null
          ? () => saveArchivedAttachmentMobile(context, attachment!)
          : null,
      onInfo: proof == null
          ? null
          : () => showMessageProofDialog(context, proof(profiles)),
    );
  }
}

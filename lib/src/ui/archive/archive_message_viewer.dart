import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/archive/shared/archive_file_actions.dart';
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/media/media_viewer_scope.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the jump-to-date picker over [timestamps] (oldest first) and hands the
/// pick to the list.
Future<void> jumpToArchiveDate(
    BuildContext context, WidgetRef ref, List<DateTime> timestamps) async {
  if (timestamps.isEmpty) return;
  final picked = await pickArchiveDate(context,
      first: timestamps.first, last: timestamps.last);
  if (picked != null) {
    ref.read(archiveJumpToDateProvider.notifier).state = picked;
  }
}

/// Opens or closes the in-conversation search, clearing it on close.
void toggleArchiveSearch(WidgetRef ref) {
  final open = ref.read(archiveMessageSearchOpenProvider);
  ref.read(archiveMessageSearchOpenProvider.notifier).state = !open;
  if (open) {
    ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
    ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
  }
}

/// A failed history load, with the one thing to do about it. [touch] on a
/// phone, where the retry takes the touch target.
Widget archiveLoadError(VoidCallback retry, {bool touch = false}) =>
    HollowEmptyState(
      title: "These messages didn't load",
      action: HollowButton.ghost(
        compact: !touch,
        touch: touch,
        onPressed: retry,
        child: const Text('Try again'),
      ),
    );

/// The reading pane of Messages: nothing picked, a DM, or a channel.
class ArchiveMessageViewer extends ConsumerWidget {
  const ArchiveMessageViewer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedDm = ref.watch(archiveSelectedDmProvider);
    final selectedChannel = ref.watch(archiveSelectedChannelProvider);

    if (selectedDm != null) {
      return _ArchiveDmViewer(key: ValueKey('dm:$selectedDm'), peerId: selectedDm);
    }
    if (selectedChannel != null) {
      final parts = selectedChannel.split(':');
      return _ArchiveChannelViewer(
        key: ValueKey('ch:$selectedChannel'),
        serverId: parts[0],
        channelId: parts.sublist(1).join(':'),
      );
    }
    return const HollowEmptyState(
      glyph: LucideIcons.archive,
      title: 'Pick a conversation to read it back',
      description: 'Everything here stays on this device, deleted and edited '
          'messages included.',
    );
  }
}

class _ArchiveDmViewer extends ConsumerWidget {
  final String peerId;

  const _ArchiveDmViewer({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final messagesAsync = ref.watch(archiveDmMessagesProvider(peerId));
    final isSaved = peerId == ref.watch(savedMessagesPeerIdProvider);
    final peerProfile = ref.watch(profileProvider.select((p) => p[peerId]));
    final displayName =
        isSaved ? 'Saved messages' : displayNameForPeer(peerProfile, peerId);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final allMessages = messagesAsync.valueOrNull ?? const <ChatMessage>[];

    return ColoredBox(
      color: hollow.background,
      child: Column(
        children: [
          ArchiveToolbar(
            leading: isSaved
                ? const SavedMessagesAvatar(size: 24)
                : HollowAvatar(peerId: peerId, size: 24),
            title: displayName,
            messageCount: messagesAsync.hasValue ? allMessages.length : null,
            onJumpToDate: allMessages.isNotEmpty
                ? () => jumpToArchiveDate(context, ref,
                    [for (final m in allMessages) m.timestamp])
                : null,
            searchOpen: searchOpen,
            onToggleSearch: () => toggleArchiveSearch(ref),
            onExport: () => showExportArchiveDialog(
              context,
              isDm: true,
              peerId: peerId,
              name: displayName,
              messageCount: allMessages.length,
            ),
          ),
          Expanded(
            child: messagesAsync.when(
              loading: () =>
                  const Center(child: HollowSpinner.large(delayed: true)),
              error: (_, _) => archiveLoadError(
                  () => ref.invalidate(archiveDmMessagesProvider(peerId))),
              data: (messages) =>
                  _DmMessageList(messages: messages, peerId: peerId),
            ),
          ),
        ],
      ),
    );
  }
}

class _DmMessageList extends ConsumerWidget {
  final List<ChatMessage> messages;
  final String peerId;

  const _DmMessageList({required this.messages, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final editsMap =
        ref.watch(archiveDmEditsProvider(peerId)).valueOrNull ?? {};

    return MediaViewerScope(
      // Read-only: an archived file can be saved and nothing else.
      actions: MediaViewerActions(
          onSaveAs: (a) => saveArchivedAttachment(context, ref, a)),
      child: ArchiveDmMessageList(
        messages: messages,
        peerId: peerId,
        localPeerId: localPeerId,
        editsMap: editsMap,
        proofContextFor: (msg) => msg.isMe ? peerId : localPeerId,
        proofMsgType: 'dm',
        desktopChrome: true,
        actionWrapper: (context, msg, child) {
          final senderPeerId = msg.isMe ? localPeerId : peerId;
          return archiveHoverActions(
            context: context,
            ref: ref,
            isMe: msg.isMe,
            messageId: msg.messageId,
            text: msg.text,
            attachment: msg.fileAttachment,
            onInfo: () => showMessageProofDialog(
              context,
              MessageProofData(
                senderPeerId: senderPeerId,
                senderDisplayName: displayNameFor(profiles, senderPeerId),
                text: msg.text,
                timestampMs:
                    (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
                signature: msg.signature,
                publicKey: msg.publicKey,
                messageId: msg.messageId,
                context: msg.isMe ? peerId : localPeerId,
                msgType: 'dm',
                fileAttachment: msg.fileAttachment,
                preverified: msg.archiveSignatureValid,
              ),
            ),
            child: child,
          );
        },
      ),
    );
  }
}

class _ArchiveChannelViewer extends ConsumerWidget {
  final String serverId;
  final String channelId;

  const _ArchiveChannelViewer({
    super.key,
    required this.serverId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
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

    return ColoredBox(
      color: hollow.background,
      child: Column(
        children: [
          ArchiveToolbar(
            leading: Icon(LucideIcons.hash, size: 20, color: hollow.textSecondary),
            title: channelName,
            subtitle: serverName,
            messageCount: messagesAsync.hasValue ? filtered.length : null,
            totalMessageCount: filterSender != null ? allMessages.length : null,
            senderIds: uniqueSenders,
            selectedSender: filterSender,
            senderDisplayNames: {
              for (final id in uniqueSenders) id: displayNameFor(profiles, id),
            },
            onSenderFilterChanged: (sender) {
              ref.read(archiveFilterSenderProvider.notifier).state = sender;
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
            onJumpToDate: filtered.isNotEmpty
                ? () => jumpToArchiveDate(
                    context, ref, [for (final m in filtered) m.timestamp])
                : null,
            searchOpen: searchOpen,
            onToggleSearch: () => toggleArchiveSearch(ref),
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
          Expanded(
            child: messagesAsync.when(
              loading: () =>
                  const Center(child: HollowSpinner.large(delayed: true)),
              error: (_, _) => archiveLoadError(
                  () => ref.invalidate(archiveChannelMessagesProvider(key))),
              data: (_) => _ChannelMessageList(
                messages: filtered,
                allMessages: allMessages,
                serverId: serverId,
                channelId: channelId,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelMessageList extends ConsumerWidget {
  final List<ChannelChatMessage> messages;
  /// Full unfiltered list for reply lookups when a sender filter is active.
  final List<ChannelChatMessage> allMessages;
  final String serverId;
  final String channelId;

  const _ChannelMessageList({
    required this.messages,
    required this.allMessages,
    required this.serverId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profileProvider);
    final proofContext = '$serverId:$channelId';
    final editsMap =
        ref.watch(archiveChannelEditsProvider(proofContext)).valueOrNull ?? {};

    return MediaViewerScope(
      // Read-only: an archived file can be saved and nothing else.
      actions: MediaViewerActions(
          onSaveAs: (a) => saveArchivedAttachment(context, ref, a)),
      child: ArchiveChannelMessageList(
        messages: messages,
        allMessages: allMessages,
        serverId: serverId,
        editsMap: editsMap,
        proofContext: proofContext,
        proofMsgType: 'ch',
        desktopChrome: true,
        actionWrapper: (context, msg, child) => archiveHoverActions(
          context: context,
          ref: ref,
          isMe: msg.isMe,
          messageId: msg.messageId,
          text: msg.text,
          attachment: msg.fileAttachment,
          onInfo: () => showMessageProofDialog(
            context,
            MessageProofData(
              senderPeerId: msg.senderId,
              senderDisplayName: displayNameFor(profiles, msg.senderId),
              text: msg.text,
              timestampMs:
                  (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
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
}

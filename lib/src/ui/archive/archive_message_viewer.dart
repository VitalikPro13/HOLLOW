import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Right panel of "My Data" — shows empty state or a read-only message viewer.
class ArchiveMessageViewer extends ConsumerStatefulWidget {
  const ArchiveMessageViewer({super.key});

  @override
  ConsumerState<ArchiveMessageViewer> createState() =>
      _ArchiveMessageViewerState();
}

class _ArchiveMessageViewerState extends ConsumerState<ArchiveMessageViewer> {
  String? _prevDm;
  String? _prevChannel;

  void _resetOnConversationChange(String? dm, String? channel) {
    if (dm != _prevDm || channel != _prevChannel) {
      _prevDm = dm;
      _prevChannel = channel;
      // Reset filter, search, and jump-to-date state.
      ref.read(archiveFilterSenderProvider.notifier).state = null;
      ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
      ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
      ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
      ref.read(archiveJumpToDateProvider.notifier).state = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final selectedDm = ref.watch(archiveSelectedDmProvider);
    final selectedChannel = ref.watch(archiveSelectedChannelProvider);

    _resetOnConversationChange(selectedDm, selectedChannel);

    if (selectedDm == null && selectedChannel == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              LucideIcons.archive,
              size: 64,
              color: hollow.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Text(
              'Select a conversation to browse your message history',
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    if (selectedDm != null) {
      return _ArchiveDmViewer(
          key: ValueKey('dm:$selectedDm'), peerId: selectedDm);
    }

    final parts = selectedChannel!.split(':');
    final serverId = parts[0];
    final channelId = parts.sublist(1).join(':');
    return _ArchiveChannelViewer(
      key: ValueKey('ch:$selectedChannel'),
      serverId: serverId,
      channelId: channelId,
    );
  }
}

// ── DM Viewer ───────────────────────────────────────────────────

class _ArchiveDmViewer extends ConsumerWidget {
  final String peerId;

  const _ArchiveDmViewer({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final messagesAsync = ref.watch(archiveDmMessagesProvider(peerId));
    final peerProfile = ref.watch(
        profileProvider.select((p) => p[peerId]));
    final displayName = displayNameForPeer(peerProfile, peerId);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);

    final allMessages = messagesAsync.valueOrNull ?? [];

    return Container(
      color: hollow.background,
      child: Column(
        children: [
          ArchiveToolbar(
            leading: HollowAvatar(
              peerId: peerId,
              size: 24,
            ),
            title: displayName,
            messageCount: allMessages.length,
            onJumpToDate: allMessages.isNotEmpty
                ? () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: allMessages.last.timestamp,
                      firstDate: allMessages.first.timestamp,
                      lastDate: allMessages.last.timestamp,
                      builder: (context, child) => Theme(
                        data: ThemeData.dark().copyWith(
                          colorScheme: ColorScheme.dark(
                            primary: hollow.accent,
                            surface: hollow.surface,
                          ),
                        ),
                        child: child!,
                      ),
                    );
                    if (picked != null) {
                      ref.read(archiveJumpToDateProvider.notifier).state = picked;
                    }
                  }
                : null,
            searchOpen: searchOpen,
            onToggleSearch: () {
              final open = ref.read(archiveMessageSearchOpenProvider);
              ref.read(archiveMessageSearchOpenProvider.notifier).state = !open;
              if (open) {
                ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
                ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
              }
            },
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
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text('Failed to load messages: $e',
                    style: TextStyle(color: hollow.error)),
              ),
              data: (messages) => _DmMessageList(
                messages: messages,
                peerId: peerId,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DmMessageList extends ConsumerStatefulWidget {
  final List<ChatMessage> messages;
  final String peerId;

  const _DmMessageList({required this.messages, required this.peerId});

  @override
  ConsumerState<_DmMessageList> createState() => _DmMessageListState();
}

class _DmMessageListState extends ConsumerState<_DmMessageList> {
  bool _isPicking = false;

  @override
  Widget build(BuildContext context) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final editsMap =
        ref.watch(archiveDmEditsProvider(widget.peerId)).valueOrNull ?? {};

    return ArchiveDmMessageList(
      messages: widget.messages,
      peerId: widget.peerId,
      localPeerId: localPeerId,
      editsMap: editsMap,
      proofContextFor: (msg) => msg.isMe ? widget.peerId : localPeerId,
      proofMsgType: 'dm',
      desktopChrome: true,
      // Hover actions (Save, Copy, Copy Image, Message Proof).
      actionWrapper: (context, msg, child) {
        final senderPeerId = msg.isMe ? localPeerId : widget.peerId;
        return MessageHoverWrapper(
          isMe: msg.isMe,
          messageId: msg.messageId,
          currentText: msg.text,
          onDownload: msg.fileAttachment != null &&
                  msg.fileAttachment!.diskPath != null
              ? () => _saveFile(msg.fileAttachment!)
              : null,
          onCopy: msg.text.isNotEmpty &&
                  !msg.text.startsWith('[file:')
              ? () {
                  Clipboard.setData(ClipboardData(text: msg.text));
                  HollowToast.show(context, 'Copied to clipboard',
                      type: HollowToastType.success);
                }
              : null,
          onCopyImage: msg.fileAttachment != null &&
                  msg.fileAttachment!.diskPath != null &&
                  msg.fileAttachment!.isImage
              ? () async {
                  final ok = await copyImageToClipboard(
                      msg.fileAttachment!.diskPath!);
                  // itemBuilder shadows the State's context — check THIS element.
                  if (context.mounted) {
                    HollowToast.show(
                      context,
                      ok
                          ? 'Image copied to clipboard'
                          : 'Failed to copy image',
                      type: ok
                          ? HollowToastType.success
                          : HollowToastType.error,
                    );
                  }
                }
              : null,
          onInfo: () {
            showMessageProofDialog(
              context,
              MessageProofData(
                senderPeerId: senderPeerId,
                senderDisplayName:
                    displayNameFor(profiles, senderPeerId),
                text: msg.text,
                timestampMs: (msg.editedAt ?? msg.timestamp)
                    .millisecondsSinceEpoch,
                signature: msg.signature,
                publicKey: msg.publicKey,
                messageId: msg.messageId,
                context: msg.isMe ? widget.peerId : localPeerId,
                msgType: 'dm',
                fileAttachment: msg.fileAttachment,
                preverified: msg.archiveSignatureValid,
              ),
            );
          },
          child: child,
        );
      },
    );
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final isImage = attachment.isImage;
      final isGif = attachment.fileExt.toLowerCase() == 'gif';
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp', 'gif']
          : [attachment.fileExt];

      final baseName = attachment.fileName.contains('.')
          ? attachment.fileName
              .substring(0, attachment.fileName.lastIndexOf('.'))
          : attachment.fileName;

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: isImage
            ? (isGif ? '$baseName.gif' : '$baseName.png')
            : attachment.fileName,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      if (savePath == null || attachment.diskPath == null) return;

      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;

      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        final converted = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: targetExt,
        );
        await File(savePath).writeAsBytes(converted);
      } else {
        await File(attachment.diskPath!).copy(savePath);
      }

      ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
            savedPath: savePath,
            isImage: isImage,
            isVideo: attachment.videoThumb != null,
          );

      if (mounted) {
        HollowToast.show(context, 'File saved',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e',
            type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }
}

// ── Channel Viewer ──────────────────────────────────────────────

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

    // Get channel/server name from the channel list provider.
    final channelGroups = ref.watch(archiveChannelListProvider).valueOrNull;
    String channelName = channelId;
    String serverName = serverId;
    if (channelGroups != null) {
      for (final group in channelGroups) {
        for (final ch in group.channels) {
          if (ch.serverId == serverId && ch.channelId == channelId) {
            channelName = ch.channelName;
            serverName = ch.serverName;
            break;
          }
        }
      }
    }

    final allMessages = messagesAsync.valueOrNull ?? [];
    final uniqueSenders = allMessages.map((m) => m.senderId).toSet().toList()..sort();
    final profiles = ref.watch(profileProvider);
    final senderNames = {
      for (final id in uniqueSenders) id: displayNameFor(profiles, id),
    };
    final senderAvatars = {
      for (final id in uniqueSenders) id: profiles[id]?.avatarBytes,
    };
    final filtered = filterSender == null
        ? allMessages
        : allMessages.where((m) => m.senderId == filterSender).toList();

    return Container(
      color: hollow.background,
      child: Column(
        children: [
          ArchiveToolbar(
            leading: Text(
              '#',
              style: TextStyle(
                color: hollow.textSecondary,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            title: channelName,
            subtitle: 'in $serverName',
            messageCount: filtered.length,
            totalMessageCount: filterSender != null ? allMessages.length : null,
            senderIds: uniqueSenders,
            selectedSender: filterSender,
            senderDisplayNames: senderNames,
            senderAvatars: senderAvatars,
            onSenderFilterChanged: (sender) {
              ref.read(archiveFilterSenderProvider.notifier).state = sender;
              // Reset search state when filter changes.
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
            onJumpToDate: allMessages.isNotEmpty
                ? () async {
                    final msgs = filtered;
                    if (msgs.isEmpty) return;
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: msgs.last.timestamp,
                      firstDate: msgs.first.timestamp,
                      lastDate: msgs.last.timestamp,
                      builder: (context, child) => Theme(
                        data: ThemeData.dark().copyWith(
                          colorScheme: ColorScheme.dark(
                            primary: hollow.accent,
                            surface: hollow.surface,
                          ),
                        ),
                        child: child!,
                      ),
                    );
                    if (picked != null) {
                      ref.read(archiveJumpToDateProvider.notifier).state = picked;
                    }
                  }
                : null,
            searchOpen: searchOpen,
            onToggleSearch: () {
              final open = ref.read(archiveMessageSearchOpenProvider);
              ref.read(archiveMessageSearchOpenProvider.notifier).state = !open;
              if (open) {
                ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
                ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
              }
            },
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
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Text('Failed to load messages: $e',
                    style: TextStyle(color: hollow.error)),
              ),
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

class _ChannelMessageList extends ConsumerStatefulWidget {
  final List<ChannelChatMessage> messages;
  /// Full unfiltered list for reply lookups when peer filter is active.
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
  ConsumerState<_ChannelMessageList> createState() =>
      _ChannelMessageListState();
}

class _ChannelMessageListState extends ConsumerState<_ChannelMessageList> {
  bool _isPicking = false;

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profileProvider);
    final editsMap = ref
            .watch(archiveChannelEditsProvider(
                '${widget.serverId}:${widget.channelId}'))
            .valueOrNull ??
        {};

    return ArchiveChannelMessageList(
      messages: widget.messages,
      allMessages: widget.allMessages,
      serverId: widget.serverId,
      editsMap: editsMap,
      proofContext: '${widget.serverId}:${widget.channelId}',
      proofMsgType: 'ch',
      desktopChrome: true,
      // Hover actions (Save, Copy, Copy Image, Message Proof).
      actionWrapper: (context, msg, child) => MessageHoverWrapper(
        isMe: msg.isMe,
        messageId: msg.messageId,
        currentText: msg.text,
        onDownload: msg.fileAttachment != null &&
                msg.fileAttachment!.diskPath != null
            ? () => _saveFile(msg.fileAttachment!)
            : null,
        onCopy: msg.text.isNotEmpty &&
                !msg.text.startsWith('[file:')
            ? () {
                Clipboard.setData(ClipboardData(text: msg.text));
                HollowToast.show(context, 'Copied to clipboard',
                    type: HollowToastType.success);
              }
            : null,
        onCopyImage: msg.fileAttachment != null &&
                msg.fileAttachment!.diskPath != null &&
                msg.fileAttachment!.isImage
            ? () async {
                final ok = await copyImageToClipboard(
                    msg.fileAttachment!.diskPath!);
                // itemBuilder shadows the State's context — check THIS element.
                if (context.mounted) {
                  HollowToast.show(
                    context,
                    ok
                        ? 'Image copied to clipboard'
                        : 'Failed to copy image',
                    type: ok
                        ? HollowToastType.success
                        : HollowToastType.error,
                  );
                }
              }
            : null,
        onInfo: () {
          showMessageProofDialog(
            context,
            MessageProofData(
              senderPeerId: msg.senderId,
              senderDisplayName:
                  displayNameFor(profiles, msg.senderId),
              text: msg.text,
              timestampMs: (msg.editedAt ?? msg.timestamp)
                  .millisecondsSinceEpoch,
              signature: msg.signature,
              publicKey: msg.publicKey,
              messageId: msg.messageId,
              context:
                  '${widget.serverId}:${widget.channelId}',
              msgType: 'ch',
              fileAttachment: msg.fileAttachment,
              preverified: msg.archiveSignatureValid,
            ),
          );
        },
        child: child,
      ),
    );
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final isImage = attachment.isImage;
      final isGif = attachment.fileExt.toLowerCase() == 'gif';
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp', 'gif']
          : [attachment.fileExt];

      final baseName = attachment.fileName.contains('.')
          ? attachment.fileName
              .substring(0, attachment.fileName.lastIndexOf('.'))
          : attachment.fileName;

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: isImage
            ? (isGif ? '$baseName.gif' : '$baseName.png')
            : attachment.fileName,
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
      );
      if (savePath == null || attachment.diskPath == null) return;

      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;

      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        final converted = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: targetExt,
        );
        await File(savePath).writeAsBytes(converted);
      } else {
        await File(attachment.diskPath!).copy(savePath);
      }

      ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
            savedPath: savePath,
            isImage: isImage,
            isVideo: attachment.videoThumb != null,
          );

      if (mounted) {
        HollowToast.show(context, 'File saved',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e',
            type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }
}

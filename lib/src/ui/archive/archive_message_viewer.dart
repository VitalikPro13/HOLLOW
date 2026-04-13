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
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart'
    show shouldGroup, shouldShowDateSeparator, DateSeparator;
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

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
    final profiles = ref.watch(profileProvider);
    final displayName = displayNameFor(profiles, peerId);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);

    final allMessages = messagesAsync.valueOrNull ?? [];

    return Container(
      color: hollow.background,
      child: Column(
        children: [
          _ArchiveHeader(
            leading: HollowAvatar(
              peerId: peerId,
              size: 24,
              imageBytes: profiles[peerId]?.avatarBytes,
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
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  int? _highlightIndex;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listen(archiveJumpToDateProvider, (_, date) {
        if (date != null && widget.messages.isNotEmpty) {
          _jumpToDate(date);
          ref.read(archiveJumpToDateProvider.notifier).state = null;
        }
      });
    });
  }

  void _jumpToDate(DateTime target) {
    final targetStart = DateTime(target.year, target.month, target.day);
    int lo = 0, hi = widget.messages.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (widget.messages[mid].timestamp.isBefore(targetStart)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < widget.messages.length && _itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: lo,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
    }
  }

  void _scrollToIndex(int index) {
    if (!_itemScrollController.isAttached) return;
    setState(() => _highlightIndex = index);
    _itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final messages = widget.messages;
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final searchQuery = ref.watch(archiveMessageSearchQueryProvider);
    final matchIdx = ref.watch(archiveSearchMatchIndexProvider);

    final matchIndices = <int>[];
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      for (int i = 0; i < messages.length; i++) {
        if (messages[i].text.toLowerCase().contains(q)) {
          matchIndices.add(i);
        }
      }
    }

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary)),
      );
    }

    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final editsMap = ref.watch(archiveDmEditsProvider(widget.peerId)).valueOrNull ?? {};

    return Column(
      children: [
        if (searchOpen)
          ArchiveSearchBar(
            matchCount: matchIndices.length,
            currentMatch: matchIdx,
            onQueryChanged: (q) {
              ref.read(archiveMessageSearchQueryProvider.notifier).state = q;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
            onNext: matchIndices.isNotEmpty
                ? () {
                    final next = (matchIdx + 1) % matchIndices.length;
                    ref.read(archiveSearchMatchIndexProvider.notifier).state = next;
                    _scrollToIndex(matchIndices[next]);
                  }
                : null,
            onPrev: matchIndices.isNotEmpty
                ? () {
                    final prev = (matchIdx - 1 + matchIndices.length) %
                        matchIndices.length;
                    ref.read(archiveSearchMatchIndexProvider.notifier).state = prev;
                    _scrollToIndex(matchIndices[prev]);
                  }
                : null,
            onClose: () {
              ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
          ),
        Expanded(
          child: MessageActionBarScope(
      child: Builder(
        builder: (scopeContext) => NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              MessageActionBarScope.of(scopeContext)?.dismissAll();
            }
            return false;
          },
          child: SelectionArea(
            contextMenuBuilder: (_, __) => const SizedBox.shrink(),
            child: ScrollablePositionedList.builder(
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        padding: const EdgeInsets.symmetric(
          vertical: HollowSpacing.sm,
        ),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final msg = messages[index];
          final prev = index > 0 ? messages[index - 1] : null;

          final showDate = shouldShowDateSeparator(
            msg.timestamp,
            prev?.timestamp,
          );

          final showHeader = prev == null ||
              showDate ||
              !shouldGroup(
                currentIsMe: msg.isMe,
                previousIsMe: prev.isMe,
                currentTime: msg.timestamp,
                previousTime: prev.timestamp,
              );

          // Look up reply text.
          String? replyToText;
          String? replyToSenderName;
          if (msg.replyToMid != null) {
            final replyMsg = messages
                .where((m) => m.messageId == msg.replyToMid)
                .firstOrNull;
            if (replyMsg != null) {
              replyToText = replyMsg.fileAttachment != null
                  ? (replyMsg.fileAttachment!.isImage
                      ? '\u{1F4F7} Image'
                      : '\u{1F4CE} ${replyMsg.fileAttachment!.fileName}')
                  : replyMsg.text;
              replyToSenderName = replyMsg.isMe
                  ? displayNameFor(profiles, localPeerId)
                  : displayNameFor(profiles, widget.peerId);
            }
          }

          final isCurrentMatch = matchIndices.isNotEmpty &&
              matchIdx < matchIndices.length &&
              matchIndices[matchIdx] == index;

          Widget bubble = MessageBubble(
            message: msg,
            peerId: widget.peerId,
            showHeader: showHeader,
            replyToText: replyToText,
            replyToSenderName: replyToSenderName,
            isHighlighted: _highlightIndex == index || isCurrentMatch,
            onReplyTap: null,
            onToggleReaction: null,
          );

          // Deleted message overlay.
          if (msg.hiddenAt != null) {
            bubble =
                _DeletedOverlay(hiddenAt: msg.hiddenAt!, child: bubble);
          }

          // Edit history indicator.
          final msgEdits = msg.messageId != null ? editsMap[msg.messageId] : null;
          final senderPeerId =
              msg.isMe ? localPeerId : widget.peerId;
          if (msgEdits != null && msgEdits.isNotEmpty) {
            bubble = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bubble,
                EditHistoryIndicator(
                  edits: msgEdits,
                  senderPeerId: senderPeerId,
                  proofContext: msg.isMe ? widget.peerId : localPeerId,
                  proofMsgType: 'dm',
                  messageId: msg.messageId,
                ),
              ],
            );
          }

          // Wrap with hover actions (Save, Copy, Copy Image, Message Proof).

          bubble = MessageHoverWrapper(
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
                    if (mounted) {
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
                  senderAvatar: profiles[senderPeerId]?.avatarBytes,
                  text: msg.text,
                  timestampMs: (msg.editedAt ?? msg.timestamp)
                      .millisecondsSinceEpoch,
                  signature: msg.signature,
                  publicKey: msg.publicKey,
                  messageId: msg.messageId,
                  context: msg.isMe ? widget.peerId : localPeerId,
                  msgType: 'dm',
                  fileAttachment: msg.fileAttachment,
                ),
              );
            },
            child: bubble,
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDate) DateSeparator(date: msg.timestamp),
              bubble,
            ],
          );
        },
      ),
    ),
    ),
    ),
    ),
        ),
      ],
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
          _ArchiveHeader(
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
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  int? _highlightIndex;

  @override
  void initState() {
    super.initState();
    // Listen for jump-to-date requests.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listen(archiveJumpToDateProvider, (_, date) {
        if (date != null && widget.messages.isNotEmpty) {
          _jumpToDate(date);
          ref.read(archiveJumpToDateProvider.notifier).state = null;
        }
      });
    });
  }

  void _jumpToDate(DateTime target) {
    final targetStart = DateTime(target.year, target.month, target.day);
    int lo = 0, hi = widget.messages.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (widget.messages[mid].timestamp.isBefore(targetStart)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < widget.messages.length && _itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: lo,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
    }
  }

  void _scrollToIndex(int index) {
    if (!_itemScrollController.isAttached) return;
    setState(() => _highlightIndex = index);
    _itemScrollController.scrollTo(
      index: index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final messages = widget.messages;
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final searchQuery = ref.watch(archiveMessageSearchQueryProvider);
    final matchIdx = ref.watch(archiveSearchMatchIndexProvider);

    // Compute search matches.
    final matchIndices = <int>[];
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      for (int i = 0; i < messages.length; i++) {
        if (messages[i].text.toLowerCase().contains(q)) {
          matchIndices.add(i);
        }
      }
    }

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary)),
      );
    }

    final profiles = ref.watch(profileProvider);
    final editsMap = ref.watch(
        archiveChannelEditsProvider('${widget.serverId}:${widget.channelId}')).valueOrNull ?? {};

    return Column(
      children: [
        // Search bar.
        if (searchOpen)
          ArchiveSearchBar(
            matchCount: matchIndices.length,
            currentMatch: matchIdx,
            onQueryChanged: (q) {
              ref.read(archiveMessageSearchQueryProvider.notifier).state = q;
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
            onNext: matchIndices.isNotEmpty
                ? () {
                    final next = (matchIdx + 1) % matchIndices.length;
                    ref.read(archiveSearchMatchIndexProvider.notifier).state = next;
                    _scrollToIndex(matchIndices[next]);
                  }
                : null,
            onPrev: matchIndices.isNotEmpty
                ? () {
                    final prev = (matchIdx - 1 + matchIndices.length) %
                        matchIndices.length;
                    ref.read(archiveSearchMatchIndexProvider.notifier).state = prev;
                    _scrollToIndex(matchIndices[prev]);
                  }
                : null,
            onClose: () {
              ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
              ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
              ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
            },
          ),
        Expanded(
          child: MessageActionBarScope(
      child: Builder(
        builder: (scopeContext) => NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollUpdateNotification) {
              MessageActionBarScope.of(scopeContext)?.dismissAll();
            }
            return false;
          },
          child: SelectionArea(
            contextMenuBuilder: (_, __) => const SizedBox.shrink(),
            child: ScrollablePositionedList.builder(
        itemScrollController: _itemScrollController,
        itemPositionsListener: _itemPositionsListener,
        padding: const EdgeInsets.symmetric(
          vertical: HollowSpacing.sm,
        ),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final msg = messages[index];
          final prev = index > 0 ? messages[index - 1] : null;

          final showDate = shouldShowDateSeparator(
            msg.timestamp,
            prev?.timestamp,
          );

          final showHeader = prev == null ||
              showDate ||
              !shouldGroup(
                currentIsMe: msg.isMe,
                previousIsMe: prev.isMe,
                currentTime: msg.timestamp,
                previousTime: prev.timestamp,
                currentSenderId: msg.senderId,
                previousSenderId: prev.senderId,
              );

          // Look up reply text from full (unfiltered) message list.
          String? replyToText;
          String? replyToSenderName;
          if (msg.replyToMid != null) {
            final replyMsg = widget.allMessages
                .where((m) => m.messageId == msg.replyToMid)
                .firstOrNull;
            if (replyMsg != null) {
              replyToText = replyMsg.fileAttachment != null
                  ? (replyMsg.fileAttachment!.isImage
                      ? '\u{1F4F7} Image'
                      : '\u{1F4CE} ${replyMsg.fileAttachment!.fileName}')
                  : replyMsg.text;
              replyToSenderName =
                  displayNameFor(profiles, replyMsg.senderId);
            }
          }

          final isCurrentMatch = matchIndices.isNotEmpty &&
              matchIdx < matchIndices.length &&
              matchIndices[matchIdx] == index;

          Widget bubble = ChannelMessageBubble(
            message: msg,
            serverId: widget.serverId,
            showHeader: showHeader,
            replyToText: replyToText,
            replyToSenderName: replyToSenderName,
            isHighlighted: _highlightIndex == index || isCurrentMatch,
            onReplyTap: null,
            onToggleReaction: null,
          );

          // Deleted message overlay.
          if (msg.hiddenAt != null) {
            bubble =
                _DeletedOverlay(hiddenAt: msg.hiddenAt!, child: bubble);
          }

          // Edit history indicator.
          final msgEdits = msg.messageId != null ? editsMap[msg.messageId] : null;
          if (msgEdits != null && msgEdits.isNotEmpty) {
            bubble = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bubble,
                EditHistoryIndicator(
                  edits: msgEdits,
                  senderPeerId: msg.senderId,
                  proofContext: '${widget.serverId}:${widget.channelId}',
                  proofMsgType: 'ch',
                  messageId: msg.messageId,
                ),
              ],
            );
          }

          // Wrap with hover actions.
          bubble = MessageHoverWrapper(
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
                    if (mounted) {
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
                  senderAvatar: profiles[msg.senderId]?.avatarBytes,
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
                ),
              );
            },
            child: bubble,
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDate) DateSeparator(date: msg.timestamp),
              bubble,
            ],
          );
        },
      ),
    ),
    ),
    ),
    ),
        ),
      ],
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

// ── Shared header ───────────────────────────────────────────────

class _ArchiveHeader extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final int? messageCount;
  final int? totalMessageCount;
  final VoidCallback? onExport;
  final VoidCallback? onJumpToDate;
  final VoidCallback? onToggleSearch;
  final bool searchOpen;
  /// Filter controls (channel only).
  final List<String>? senderIds;
  final String? selectedSender;
  final ValueChanged<String?>? onSenderFilterChanged;
  final Map<String, String>? senderDisplayNames;
  final Map<String, dynamic>? senderAvatars;

  const _ArchiveHeader({
    required this.leading,
    required this.title,
    this.subtitle,
    this.messageCount,
    this.totalMessageCount,
    this.onExport,
    this.onJumpToDate,
    this.onToggleSearch,
    this.searchOpen = false,
    this.senderIds,
    this.selectedSender,
    this.onSenderFilterChanged,
    this.senderDisplayNames,
    this.senderAvatars,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final countText = selectedSender != null && totalMessageCount != null
        ? '$messageCount of $totalMessageCount'
        : '${messageCount ?? 0}';

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: subtitle != null
                ? Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: title,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: '  $subtitle',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    title,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if (messageCount != null)
            Text(
              '$countText messages',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
          // Peer filter (channel archives only).
          if (senderIds != null && senderIds!.length > 1) ...[
            const SizedBox(width: HollowSpacing.xs),
            _FilterButton(
              senderIds: senderIds!,
              selectedSender: selectedSender,
              senderDisplayNames: senderDisplayNames ?? {},
              senderAvatars: senderAvatars ?? {},
              onSenderFilterChanged: onSenderFilterChanged,
            ),
          ],
          if (onJumpToDate != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onJumpToDate,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.calendar,
                  size: 16, color: hollow.textSecondary),
            ),
          ],
          if (onToggleSearch != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onToggleSearch,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.search,
                  size: 16,
                  color: searchOpen
                      ? hollow.accent
                      : hollow.textSecondary),
            ),
          ],
          if (onExport != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onExport,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.fileOutput,
                  size: 16, color: hollow.accent),
            ),
          ],
          const SizedBox(width: HollowSpacing.sm),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: Text(
              'read-only',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Peer filter button (opens showDialog) ──────────────────────

class _FilterButton extends StatelessWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderDisplayNames;
  final Map<String, dynamic> senderAvatars;
  final ValueChanged<String?>? onSenderFilterChanged;

  const _FilterButton({
    required this.senderIds,
    this.selectedSender,
    required this.senderDisplayNames,
    this.senderAvatars = const {},
    this.onSenderFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: () async {
        final picked = await showDialog<String?>(
          context: context,
          barrierColor: Colors.transparent,
          builder: (ctx) => _FilterDialog(
            senderIds: senderIds,
            selectedSender: selectedSender,
            senderDisplayNames: senderDisplayNames,
            senderAvatars: senderAvatars,
          ),
        );
        if (picked != null) {
          // Use '_clear_' sentinel to mean "All participants".
          onSenderFilterChanged?.call(picked == '_clear_' ? null : picked);
        }
      },
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(6),
      child: Icon(
        LucideIcons.filter,
        size: 16,
        color: selectedSender != null
            ? hollow.accent
            : hollow.textSecondary,
      ),
    );
  }
}

class _FilterDialog extends StatefulWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderDisplayNames;
  final Map<String, dynamic> senderAvatars;

  const _FilterDialog({
    required this.senderIds,
    this.selectedSender,
    required this.senderDisplayNames,
    this.senderAvatars = const {},
  });

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final filtered = _query.isEmpty
        ? widget.senderIds
        : widget.senderIds.where((id) {
            final name =
                (widget.senderDisplayNames[id] ?? id).toLowerCase();
            return name.contains(_query.toLowerCase());
          }).toList();

    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 100, right: 80),
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: 240,
            constraints: const BoxConstraints(maxHeight: 360),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(HollowSpacing.sm),
                  child: HollowTextField(
                    hintText: 'Search participants...',
                    isDense: true,
                    autofocus: true,
                    prefixIcon: Icon(LucideIcons.search,
                        size: 12, color: hollow.textSecondary),
                    onChanged: (val) => setState(() => _query = val),
                  ),
                ),
                HollowPressable(
                  onTap: () => Navigator.of(context).pop('_clear_'),
                  padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.md, vertical: 6),
                  child: Row(
                    children: [
                      Icon(LucideIcons.users, size: 14,
                          color: widget.selectedSender == null
                              ? hollow.accent
                              : hollow.textSecondary),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        'All participants',
                        style: HollowTypography.body.copyWith(
                          color: widget.selectedSender == null
                              ? hollow.accent
                              : hollow.textPrimary,
                          fontWeight: widget.selectedSender == null
                              ? FontWeight.w600
                              : FontWeight.normal,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: hollow.border),
                Flexible(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        vertical: HollowSpacing.xs),
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (_, index) {
                      final id = filtered[index];
                      final name =
                          widget.senderDisplayNames[id] ?? id.substring(0, 8);
                      final isActive = widget.selectedSender == id;

                      return HollowPressable(
                        onTap: () => Navigator.of(context).pop(id),
                        padding: const EdgeInsets.symmetric(
                            horizontal: HollowSpacing.md, vertical: 5),
                        child: Row(
                          children: [
                            HollowAvatar(peerId: id, size: 20, imageBytes: widget.senderAvatars[id]),
                            const SizedBox(width: HollowSpacing.sm),
                            Expanded(
                              child: Text(
                                name,
                                style: HollowTypography.body.copyWith(
                                  color: isActive
                                      ? hollow.accent
                                      : hollow.textPrimary,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isActive)
                              Icon(LucideIcons.check,
                                  size: 14, color: hollow.accent),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Search bar for archive viewers ──────────────────────────────

class ArchiveSearchBar extends StatefulWidget {
  final int matchCount;
  final int currentMatch;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final VoidCallback onClose;

  const ArchiveSearchBar({
    required this.matchCount,
    required this.currentMatch,
    required this.onQueryChanged,
    this.onNext,
    this.onPrev,
    required this.onClose,
  });

  @override
  State<ArchiveSearchBar> createState() => ArchiveSearchBarState();
}

class ArchiveSearchBarState extends State<ArchiveSearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: HollowTextField(
              controller: _controller,
              focusNode: _focusNode,
              hintText: 'Search messages...',
              isDense: true,
              prefixIcon: Icon(LucideIcons.search,
                  size: 14, color: hollow.textSecondary),
              onChanged: widget.onQueryChanged,
              onSubmitted: (_) => widget.onNext?.call(),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (_controller.text.isNotEmpty)
            Text(
              widget.matchCount > 0
                  ? '${widget.currentMatch + 1} of ${widget.matchCount}'
                  : '0 results',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            onTap: widget.onPrev,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.chevronUp,
                size: 14,
                color: widget.onPrev != null
                    ? hollow.textPrimary
                    : hollow.textSecondary.withValues(alpha: 0.3)),
          ),
          HollowPressable(
            onTap: widget.onNext,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.chevronDown,
                size: 14,
                color: widget.onNext != null
                    ? hollow.textPrimary
                    : hollow.textSecondary.withValues(alpha: 0.3)),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            onTap: widget.onClose,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.x,
                size: 14, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ── Deleted message overlay ─────────────────────────────────────

class _DeletedOverlay extends StatelessWidget {
  final DateTime hiddenAt;
  final Widget child;

  const _DeletedOverlay({required this.hiddenAt, required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final time =
        '${hiddenAt.hour.toString().padLeft(2, '0')}:${hiddenAt.minute.toString().padLeft(2, '0')}';

    return AnimatedOpacity(
      opacity: 0.4,
      duration: Duration.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          child,
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.trash2,
                    size: 11,
                    color: hollow.error.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  'Deleted at $time',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.error.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Edit history indicator ──────────────────────────────────────

/// Shows "Edited N times -> view history" below a message bubble.
/// Tapping expands a timeline of every prior version.
class EditHistoryIndicator extends StatefulWidget {
  final List<ArchiveEditEntry> edits;
  final String? senderPeerId;
  final String? proofContext;
  final String? proofMsgType;
  /// Original message signature/publicKey/timestamp — needed to verify the
  /// first edit's oldText (the original message text before any edits).
  final String? originalSignature;
  final String? originalPublicKey;
  final int? originalTimestampMs;
  final String? messageId;

  const EditHistoryIndicator({
    super.key,
    required this.edits,
    this.senderPeerId,
    this.proofContext,
    this.proofMsgType,
    this.originalSignature,
    this.originalPublicKey,
    this.originalTimestampMs,
    this.messageId,
  });

  @override
  State<EditHistoryIndicator> createState() => _EditHistoryIndicatorState();
}

class _EditHistoryIndicatorState extends State<EditHistoryIndicator> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final count = widget.edits.length;

    return Padding(
      padding: const EdgeInsets.only(left: 42, top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowPressable(
            onTap: () => setState(() => _expanded = !_expanded),
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.pencil,
                    size: 11,
                    color: hollow.accent.withValues(alpha: 0.7)),
                const SizedBox(width: 4),
                Text(
                  'Edited $count ${count == 1 ? 'time' : 'times'}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent.withValues(alpha: 0.7),
                    fontSize: 10,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _expanded ? LucideIcons.chevronUp : LucideIcons.chevronRight,
                  size: 10,
                  color: hollow.accent.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 4),
            for (int i = 0; i < widget.edits.length; i++) ...[
              () {
                final e = widget.edits[i];
                final time =
                    '${e.editedAt.hour.toString().padLeft(2, '0')}:${e.editedAt.minute.toString().padLeft(2, '0')}';
                final dateStr =
                    '${e.editedAt.year}-${e.editedAt.month.toString().padLeft(2, '0')}-${e.editedAt.day.toString().padLeft(2, '0')}';
                // The displayed text is e.oldText (what the message was before
                // this edit). The signature that covers e.oldText is:
                //   - For i==0: the original message signature (before any edits)
                //   - For i>0: the previous edit's signature (which signed its newText,
                //     and previous newText == current oldText)
                final String? proofSig;
                final String? proofPk;
                final int? proofTs;
                if (i == 0) {
                  proofSig = e.prevSignature ?? widget.originalSignature;
                  proofPk = e.prevPublicKey ?? widget.originalPublicKey;
                  proofTs = e.prevTimestampMs ?? widget.originalTimestampMs;
                } else {
                  final prev = widget.edits[i - 1];
                  proofSig = prev.signature;
                  proofPk = prev.publicKey;
                  proofTs = prev.editedAt.millisecondsSinceEpoch;
                }
                final hasSig = proofSig != null && proofPk != null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Container(
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    decoration: BoxDecoration(
                      color: hollow.surface,
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      border: Border.all(
                          color: hollow.border.withValues(alpha: 0.5)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '$dateStr $time',
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                                fontSize: 10,
                              ),
                            ),
                            const SizedBox(width: 6),
                            HollowPressable(
                              onTap: hasSig && widget.senderPeerId != null
                                  ? () {
                                      final profiles =
                                          ProviderScope.containerOf(context)
                                              .read(profileProvider);
                                      showMessageProofDialog(
                                        context,
                                        MessageProofData(
                                          senderPeerId: widget.senderPeerId!,
                                          senderDisplayName: displayNameFor(
                                              profiles, widget.senderPeerId!),
                                          senderAvatar: profiles[widget.senderPeerId]
                                              ?.avatarBytes,
                                          text: e.oldText,
                                          timestampMs: proofTs!,
                                          signature: proofSig,
                                          publicKey: proofPk,
                                          messageId: widget.messageId ?? e.messageId,
                                          context: widget.proofContext ?? '',
                                          msgType: widget.proofMsgType ?? 'ch',
                                        ),
                                      );
                                    }
                                  : null,
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                hasSig
                                    ? LucideIcons.shieldCheck
                                    : LucideIcons.shieldOff,
                                size: 10,
                                color: hasSig
                                    ? hollow.accent.withValues(alpha: 0.6)
                                    : hollow.textSecondary.withValues(alpha: 0.4),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          e.oldText,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 12,
                            decoration: TextDecoration.lineThrough,
                            decorationColor:
                                hollow.textSecondary.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }(),
            ],
          ],
        ],
      ),
    );
  }
}

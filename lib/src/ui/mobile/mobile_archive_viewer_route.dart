import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/archive_message_viewer.dart'
    show ArchiveSearchBar, EditHistoryIndicator;
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart'
    show shouldGroup, shouldShowDateSeparator, DateSeparator;
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_message_actions.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Full-screen archive message viewer for My Data (DMs and channels).
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
  final _scrollController = ItemScrollController();
  final _positionsListener = ItemPositionsListener.create();
  int? _highlightIndex;
  bool _isPicking = false;

  @override
  void dispose() {
    // Reset search/filter state on exit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        ref.read(archiveFilterSenderProvider.notifier).state = null;
        ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
        ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
        ref.read(archiveJumpToDateProvider.notifier).state = null;
      } catch (_) {}
    });
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listen(archiveJumpToDateProvider, (_, date) {
        if (date != null) {
          _jumpToDate(date);
          ref.read(archiveJumpToDateProvider.notifier).state = null;
        }
      });
    });
  }

  void _jumpToDate(DateTime target) {
    final messages = _currentMessages;
    if (messages.isEmpty) return;
    final targetStart = DateTime(target.year, target.month, target.day);
    int lo = 0, hi = messages.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (_timestampOf(messages[mid]).isBefore(targetStart)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < messages.length && _scrollController.isAttached) {
      _scrollController.scrollTo(
        index: lo,
        duration: ReduceMotionController.instance.isReduced
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: 0.1,
      );
    }
  }

  void _scrollToIndex(int index) {
    if (!_scrollController.isAttached) return;
    setState(() => _highlightIndex = index);
    _scrollController.scrollTo(
      index: index,
      duration: ReduceMotionController.instance.isReduced
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  DateTime _timestampOf(dynamic msg) {
    if (msg is ChatMessage) return msg.timestamp;
    if (msg is ChannelChatMessage) return msg.timestamp;
    return DateTime.now();
  }

  List<dynamic> get _currentMessages {
    if (widget.isDm) {
      return ref
              .read(archiveDmMessagesProvider(widget.peerId!))
              .valueOrNull ??
          [];
    }
    final key = '${widget.serverId}:${widget.channelId}';
    final all =
        ref.read(archiveChannelMessagesProvider(key)).valueOrNull ?? [];
    final filter = ref.read(archiveFilterSenderProvider);
    if (filter == null) return all;
    return all.where((m) => m.senderId == filter).toList();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (widget.isDm) {
      return _buildDmViewer(hollow);
    }
    return _buildChannelViewer(hollow);
  }

  // ── DM Viewer ──────────────────────────────────────────────────

  Widget _buildDmViewer(HollowTheme hollow) {
    final peerId = widget.peerId!;
    final messagesAsync = ref.watch(archiveDmMessagesProvider(peerId));
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[peerId]));
    final displayName = displayNameForPeer(peerProfile, peerId);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final allMessages = messagesAsync.valueOrNull ?? [];

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            _MobileArchiveHeader(
              leading: HollowAvatar(peerId: peerId, size: 24),
              title: displayName,
              messageCount: allMessages.length,
              searchOpen: searchOpen,
              onBack: () => Navigator.pop(context),
              onToggleSearch: () => _toggleSearch(),
              onJumpToDate:
                  allMessages.isNotEmpty ? () => _pickDate(allMessages.first.timestamp, allMessages.last.timestamp) : null,
              onExport: () => showExportArchiveDialog(
                context,
                isDm: true,
                peerId: peerId,
                name: displayName,
                messageCount: allMessages.length,
              ),
            ),
            if (searchOpen) _buildSearchBar(allMessages.cast<dynamic>()),
            Expanded(
              child: AnimatedSwitcher(
                duration: ReduceMotionController.instance.isReduced
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                child: messagesAsync.when(
                  loading: () =>
                      const Center(key: ValueKey('loading'), child: CircularProgressIndicator()),
                  error: (e, _) => Center(
                    key: const ValueKey('error'),
                    child: Text('Failed to load: $e',
                        style: TextStyle(color: hollow.error)),
                  ),
                  data: (messages) =>
                      _buildDmMessageList(messages, peerId),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDmMessageList(List<ChatMessage> messages, String peerId) {
    final hollow = HollowTheme.of(context);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final editsMap =
        ref.watch(archiveDmEditsProvider(peerId)).valueOrNull ?? {};
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

    return ScrollablePositionedList.builder(
      itemScrollController: _scrollController,
      itemPositionsListener: _positionsListener,
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final prev = index > 0 ? messages[index - 1] : null;

        final showDate =
            shouldShowDateSeparator(msg.timestamp, prev?.timestamp);
        final showHeader = prev == null ||
            showDate ||
            !shouldGroup(
              currentIsMe: msg.isMe,
              previousIsMe: prev.isMe,
              currentTime: msg.timestamp,
              previousTime: prev.timestamp,
            );

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
                : displayNameFor(profiles, peerId);
          }
        }

        final isCurrentMatch = matchIndices.isNotEmpty &&
            matchIdx < matchIndices.length &&
            matchIndices[matchIdx] == index;

        final senderPeerId = msg.isMe ? localPeerId : peerId;

        Widget bubble = MessageBubble(
          message: msg,
          peerId: peerId,
          showHeader: showHeader,
          replyToText: replyToText,
          replyToSenderName: replyToSenderName,
          isHighlighted: _highlightIndex == index || isCurrentMatch,
          onReplyTap: null,
          onToggleReaction: null,
        );

        if (msg.hiddenAt != null) {
          bubble = _DeletedOverlay(hiddenAt: msg.hiddenAt!, child: bubble);
        }

        final msgEdits =
            msg.messageId != null ? editsMap[msg.messageId] : null;
        if (msgEdits != null && msgEdits.isNotEmpty) {
          bubble = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bubble,
              EditHistoryIndicator(
                edits: msgEdits,
                senderPeerId: senderPeerId,
                proofContext: msg.isMe ? peerId : localPeerId,
                proofMsgType: 'dm',
                messageId: msg.messageId,
              ),
            ],
          );
        }

        bubble = _LongPressMessage(
          onLongPress: () => _showDmMessageActions(
            msg, senderPeerId, profiles, localPeerId, peerId,
          ),
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
    );
  }

  void _showDmMessageActions(
    ChatMessage msg,
    String senderPeerId,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
    String peerId,
  ) {
    final time =
        '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
    showMobileArchiveMessageActions(
      context: context,
      messageText: msg.text,
      senderName: displayNameFor(profiles, senderPeerId),
      timestamp: time,
      onCopy: msg.text.isNotEmpty && !msg.text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: msg.text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: msg.fileAttachment != null &&
              msg.fileAttachment!.diskPath != null
          ? () => _saveFile(msg.fileAttachment!)
          : null,
      onInfo: msg.messageId != null
          ? () {
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
                  context: msg.isMe ? peerId : localPeerId,
                  msgType: 'dm',
                  fileAttachment: msg.fileAttachment,
                ),
              );
            }
          : null,
    );
  }

  // ── Channel Viewer ─────────────────────────────────────────────

  Widget _buildChannelViewer(HollowTheme hollow) {
    final key = '${widget.serverId}:${widget.channelId}';
    final messagesAsync = ref.watch(archiveChannelMessagesProvider(key));
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);

    final channelGroups =
        ref.watch(archiveChannelListProvider).valueOrNull;
    String channelName = widget.channelId ?? '';
    String serverName = widget.serverId ?? '';
    if (channelGroups != null) {
      for (final group in channelGroups) {
        for (final ch in group.channels) {
          if (ch.serverId == widget.serverId &&
              ch.channelId == widget.channelId) {
            channelName = ch.channelName;
            serverName = ch.serverName;
            break;
          }
        }
      }
    }

    final allMessages = messagesAsync.valueOrNull ?? [];
    final uniqueSenders =
        allMessages.map((m) => m.senderId).toSet().toList()..sort();
    final profiles = ref.watch(profileProvider);
    final senderNames = {
      for (final id in uniqueSenders) id: displayNameFor(profiles, id),
    };
    final filtered = filterSender == null
        ? allMessages
        : allMessages
            .where((m) => m.senderId == filterSender)
            .toList();

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            _MobileArchiveHeader(
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
              totalMessageCount:
                  filterSender != null ? allMessages.length : null,
              searchOpen: searchOpen,
              onBack: () => Navigator.pop(context),
              onToggleSearch: () => _toggleSearch(),
              onFilter: uniqueSenders.length > 1
                  ? () => _showFilterSheet(
                      uniqueSenders, filterSender, senderNames)
                  : null,
              filterActive: filterSender != null,
              onJumpToDate: filtered.isNotEmpty
                  ? () => _pickDate(
                      filtered.first.timestamp, filtered.last.timestamp)
                  : null,
              onExport: () => showExportArchiveDialog(
                context,
                isDm: false,
                serverId: widget.serverId,
                channelId: widget.channelId,
                channelName: channelName,
                name: channelName,
                messageCount: allMessages.length,
              ),
            ),
            if (searchOpen)
              _buildSearchBar(filtered.cast<dynamic>()),
            Expanded(
              child: AnimatedSwitcher(
                duration: ReduceMotionController.instance.isReduced
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOut,
                child: messagesAsync.when(
                  loading: () =>
                      const Center(key: ValueKey('loading'), child: CircularProgressIndicator()),
                  error: (e, _) => Center(
                    key: const ValueKey('error'),
                    child: Text('Failed to load: $e',
                        style: TextStyle(color: hollow.error)),
                  ),
                  data: (_) => _buildChannelMessageList(
                      filtered, allMessages),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelMessageList(
    List<ChannelChatMessage> messages,
    List<ChannelChatMessage> allMessages,
  ) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final editsMap = ref
            .watch(archiveChannelEditsProvider(
                '${widget.serverId}:${widget.channelId}'))
            .valueOrNull ??
        {};
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

    return ScrollablePositionedList.builder(
      itemScrollController: _scrollController,
      itemPositionsListener: _positionsListener,
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final msg = messages[index];
        final prev = index > 0 ? messages[index - 1] : null;

        final showDate =
            shouldShowDateSeparator(msg.timestamp, prev?.timestamp);
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

        String? replyToText;
        String? replyToSenderName;
        if (msg.replyToMid != null) {
          final replyMsg = allMessages
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
          serverId: widget.serverId!,
          showHeader: showHeader,
          replyToText: replyToText,
          replyToSenderName: replyToSenderName,
          isHighlighted: _highlightIndex == index || isCurrentMatch,
          onReplyTap: null,
          onToggleReaction: null,
        );

        if (msg.hiddenAt != null) {
          bubble = _DeletedOverlay(hiddenAt: msg.hiddenAt!, child: bubble);
        }

        final msgEdits =
            msg.messageId != null ? editsMap[msg.messageId] : null;
        if (msgEdits != null && msgEdits.isNotEmpty) {
          bubble = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bubble,
              EditHistoryIndicator(
                edits: msgEdits,
                senderPeerId: msg.senderId,
                proofContext:
                    '${widget.serverId}:${widget.channelId}',
                proofMsgType: 'ch',
                messageId: msg.messageId,
              ),
            ],
          );
        }

        bubble = _LongPressMessage(
          onLongPress: () =>
              _showChannelMessageActions(msg, profiles),
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
    );
  }

  void _showChannelMessageActions(
    ChannelChatMessage msg,
    Map<String, storage_api.UserProfile> profiles,
  ) {
    final time =
        '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
    showMobileArchiveMessageActions(
      context: context,
      messageText: msg.text,
      senderName: displayNameFor(profiles, msg.senderId),
      timestamp: time,
      onCopy: msg.text.isNotEmpty && !msg.text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: msg.text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: msg.fileAttachment != null &&
              msg.fileAttachment!.diskPath != null
          ? () => _saveFile(msg.fileAttachment!)
          : null,
      onInfo: msg.messageId != null
          ? () {
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
                ),
              );
            }
          : null,
    );
  }

  // ── Shared helpers ─────────────────────────────────────────────

  void _toggleSearch() {
    final open = ref.read(archiveMessageSearchOpenProvider);
    ref.read(archiveMessageSearchOpenProvider.notifier).state = !open;
    if (open) {
      ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
      ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
    }
  }

  Widget _buildSearchBar(List<dynamic> messages) {
    final searchQuery = ref.watch(archiveMessageSearchQueryProvider);
    final matchIdx = ref.watch(archiveSearchMatchIndexProvider);

    final matchIndices = <int>[];
    if (searchQuery.isNotEmpty) {
      final q = searchQuery.toLowerCase();
      for (int i = 0; i < messages.length; i++) {
        final text = messages[i] is ChatMessage
            ? (messages[i] as ChatMessage).text
            : (messages[i] as ChannelChatMessage).text;
        if (text.toLowerCase().contains(q)) {
          matchIndices.add(i);
        }
      }
    }

    return ArchiveSearchBar(
      matchCount: matchIndices.length,
      currentMatch: matchIdx,
      onQueryChanged: (q) {
        ref.read(archiveMessageSearchQueryProvider.notifier).state = q;
        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
      },
      onNext: matchIndices.isNotEmpty
          ? () {
              final next = (matchIdx + 1) % matchIndices.length;
              ref.read(archiveSearchMatchIndexProvider.notifier).state =
                  next;
              _scrollToIndex(matchIndices[next]);
            }
          : null,
      onPrev: matchIndices.isNotEmpty
          ? () {
              final prev =
                  (matchIdx - 1 + matchIndices.length) %
                      matchIndices.length;
              ref.read(archiveSearchMatchIndexProvider.notifier).state =
                  prev;
              _scrollToIndex(matchIndices[prev]);
            }
          : null,
      onClose: () {
        ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
        ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
      },
    );
  }

  Future<void> _pickDate(DateTime first, DateTime last) async {
    final hollow = HollowTheme.of(context);
    final picked = await showDatePicker(
      context: context,
      initialDate: last,
      firstDate: first,
      lastDate: last,
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

  void _showFilterSheet(
    List<String> senderIds,
    String? selectedSender,
    Map<String, String> senderNames,
  ) {
    final hollow = HollowTheme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      isScrollControlled: true,
      builder: (_) => _FilterSheet(
        senderIds: senderIds,
        selectedSender: selectedSender,
        senderNames: senderNames,
        onSelected: (sender) {
          ref.read(archiveFilterSenderProvider.notifier).state = sender;
          ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
          ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
        },
      ),
    );
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking || attachment.diskPath == null) return;
    _isPicking = true;
    try {
      Uint8List bytes;
      if (attachment.isImage && attachment.fileExt == 'webp') {
        bytes = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: 'png',
        );
      } else {
        bytes = await File(attachment.diskPath!).readAsBytes();
      }

      final fileName = attachment.isImage && attachment.fileExt == 'webp'
          ? '${attachment.fileName.contains('.') ? attachment.fileName.substring(0, attachment.fileName.lastIndexOf('.')) : attachment.fileName}.png'
          : attachment.fileName;

      await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: fileName,
        bytes: bytes,
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

// ── Header ─────────────────────────────────────────────────────

class _MobileArchiveHeader extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final int? messageCount;
  final int? totalMessageCount;
  final bool searchOpen;
  final VoidCallback onBack;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onFilter;
  final bool filterActive;
  final VoidCallback? onJumpToDate;
  final VoidCallback? onExport;

  const _MobileArchiveHeader({
    required this.leading,
    required this.title,
    required this.onBack,
    this.subtitle,
    this.messageCount,
    this.totalMessageCount,
    this.searchOpen = false,
    this.onToggleSearch,
    this.onFilter,
    this.filterActive = false,
    this.onJumpToDate,
    this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      height: 52,
      padding:
          const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          HollowPressable(
            onTap: onBack,
            semanticLabel: 'Back',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(8),
            child: Icon(LucideIcons.chevronLeft,
                size: 20, color: hollow.textPrimary),
          ),
          leading,
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: subtitle != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        subtitle!,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  )
                : Text(
                    title,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if (onFilter != null)
            HollowPressable(
              onTap: onFilter,
              semanticLabel: 'Filter by sender',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.filter,
                  size: 16,
                  color: filterActive
                      ? hollow.accent
                      : hollow.textSecondary),
            ),
          if (onJumpToDate != null)
            HollowPressable(
              onTap: onJumpToDate,
              semanticLabel: 'Jump to date',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.calendar,
                  size: 16, color: hollow.textSecondary),
            ),
          if (onToggleSearch != null)
            HollowPressable(
              onTap: onToggleSearch,
              semanticLabel: 'Search messages',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.search,
                  size: 16,
                  color: searchOpen
                      ? hollow.accent
                      : hollow.textSecondary),
            ),
          if (onExport != null)
            HollowPressable(
              onTap: onExport,
              semanticLabel: 'Export conversation',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.fileOutput,
                  size: 16, color: hollow.accent),
            ),
          Container(
            margin: const EdgeInsets.only(left: 4, right: 4),
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: Text(
              'read-only',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 9,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Filter bottom sheet ────────────────────────────────────────

class _FilterSheet extends StatefulWidget {
  final List<String> senderIds;
  final String? selectedSender;
  final Map<String, String> senderNames;
  final ValueChanged<String?> onSelected;

  const _FilterSheet({
    required this.senderIds,
    this.selectedSender,
    required this.senderNames,
    required this.onSelected,
  });

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final filtered = _query.isEmpty
        ? widget.senderIds
        : widget.senderIds.where((id) {
            final name =
                (widget.senderNames[id] ?? id).toLowerCase();
            return name.contains(_query.toLowerCase());
          }).toList();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.sm),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: hollow.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(HollowSpacing.md),
            child: HollowTextField(
              hintText: 'Search participants...',
              isDense: true,
              autofocus: true,
              prefixIcon: Icon(LucideIcons.search,
                  size: 14, color: hollow.textSecondary),
              onChanged: (val) => setState(() => _query = val),
            ),
          ),
          HollowPressable(
            onTap: () {
              Navigator.pop(context);
              widget.onSelected(null);
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.lg, vertical: 10),
              child: Row(
                children: [
                  Icon(LucideIcons.users,
                      size: 16,
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
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: hollow.border),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.4,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(
                  vertical: HollowSpacing.xs),
              itemCount: filtered.length,
              itemBuilder: (_, index) {
                final id = filtered[index];
                final name = widget.senderNames[id] ??
                    id.substring(0, 8);
                final isActive = widget.selectedSender == id;

                return HollowPressable(
                  onTap: () {
                    Navigator.pop(context);
                    widget.onSelected(id);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.lg,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        HollowAvatar(peerId: id, size: 24),
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
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isActive)
                          Icon(LucideIcons.check,
                              size: 16, color: hollow.accent),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }
}

// ── Deleted message overlay ────────────────────────────────────

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

// ── Long-press wrapper ─────────────────────────────────────────

class _LongPressMessage extends StatefulWidget {
  final Widget child;
  final VoidCallback onLongPress;

  const _LongPressMessage({
    required this.child,
    required this.onLongPress,
  });

  @override
  State<_LongPressMessage> createState() => _LongPressMessageState();
}

class _LongPressMessageState extends State<_LongPressMessage> {
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => setState(() => _pressing = true),
      onLongPress: () {
        setState(() => _pressing = false);
        widget.onLongPress();
      },
      onLongPressCancel: () => setState(() => _pressing = false),
      onLongPressEnd: (_) => setState(() => _pressing = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color:
              _pressing ? hollow.accent.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: widget.child,
      ),
    );
  }
}

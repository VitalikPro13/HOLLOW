import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
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
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_message_actions.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Full-screen route for viewing an imported .hollow-archive file.
class MobileImportedArchiveViewerRoute extends ConsumerStatefulWidget {
  final String path;

  const MobileImportedArchiveViewerRoute({
    super.key,
    required this.path,
  });

  @override
  ConsumerState<MobileImportedArchiveViewerRoute> createState() =>
      _MobileImportedArchiveViewerRouteState();
}

class _MobileImportedArchiveViewerRouteState
    extends ConsumerState<MobileImportedArchiveViewerRoute> {
  final _scrollController = ItemScrollController();
  final _positionsListener = ItemPositionsListener.create();
  int? _highlightIndex;
  bool _isPicking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(archiveFilterSenderProvider.notifier).state = null;
      ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
      ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
      ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
      ref.read(archiveJumpToDateProvider.notifier).state = null;
      ref.read(importedArchiveSelectedChannelProvider.notifier).state =
          null;

      ref.listen(archiveJumpToDateProvider, (_, date) {
        if (date != null) {
          _jumpToDate(date);
          ref.read(archiveJumpToDateProvider.notifier).state = null;
        }
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        ref.read(archiveFilterSenderProvider.notifier).state = null;
        ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
        ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
        ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
        ref.read(archiveJumpToDateProvider.notifier).state = null;
        ref.read(importedArchiveSelectedChannelProvider.notifier).state =
            null;
      } catch (_) {}
    });
    super.dispose();
  }

  void _jumpToDate(DateTime target) {
    final messages = _visibleMessages;
    if (messages == null || messages.isEmpty) return;
    final targetStart = DateTime(target.year, target.month, target.day);
    int lo = 0, hi = messages.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      final ts = messages[mid] is ChatMessage
          ? (messages[mid] as ChatMessage).timestamp
          : (messages[mid] as ChannelChatMessage).timestamp;
      if (ts.isBefore(targetStart)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < messages.length && _scrollController.isAttached) {
      _scrollController.scrollTo(
        index: lo,
        duration: const Duration(milliseconds: 300),
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
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  List<dynamic>? _visibleMessages;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dataAsync =
        ref.watch(importedArchiveDataProvider(widget.path));

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOut,
          child: dataAsync.when(
          loading: () =>
              const Center(key: ValueKey('loading'), child: CircularProgressIndicator()),
          error: (e, _) => Column(
            key: const ValueKey('error'),
            children: [
              _backHeader(hollow),
              Expanded(
                child: Center(
                  child: Text('Failed to load: $e',
                      style: TextStyle(color: hollow.error)),
                ),
              ),
            ],
          ),
          data: (data) => _buildArchiveViewer(hollow, data),
        ),
        ),
      ),
    );
  }

  Widget _backHeader(HollowTheme hollow) {
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
            onTap: () => Navigator.pop(context),
            semanticLabel: 'Back',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(8),
            child: Icon(LucideIcons.chevronLeft,
                size: 20, color: hollow.textPrimary),
          ),
          Text('Imported Archive',
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }

  Widget _buildArchiveViewer(
      HollowTheme hollow, archive_api.ArchiveData data) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final v = data.verification;

    final isDm = data.archiveType == 'dm';
    final isServer = data.archiveType == 'server';

    // Verification banner data
    final exportDate =
        DateTime.fromMillisecondsSinceEpoch(v.exportTimestamp);
    final dateStr =
        '${exportDate.year}-${exportDate.month.toString().padLeft(2, '0')}-${exportDate.day.toString().padLeft(2, '0')}';
    final exporterName = displayNameFor(profiles, v.exporterPeerId);

    final archiveColor =
        v.archiveSignatureValid ? hollow.accent : hollow.error;
    final archiveIcon = v.archiveSignatureValid
        ? LucideIcons.shieldCheck
        : LucideIcons.shieldOff;
    final archiveText = v.archiveSignatureValid
        ? 'Signed by $exporterName on $dateStr'
        : 'Signature invalid — may be tampered';

    final hasWarning = v.messagesWithInvalidSig > 0;
    final msgColor = hasWarning ? Colors.amber.shade700 : hollow.accent;
    final msgIcon =
        hasWarning ? LucideIcons.alertTriangle : LucideIcons.shieldCheck;
    final String msgText;
    if (hasWarning) {
      msgText =
          '${v.messagesWithInvalidSig}/${v.messageCount} messages failed verification';
    } else if (v.messagesWithValidSig > 0) {
      msgText = '${v.messagesWithValidSig} messages verified';
    } else {
      msgText = '${v.messageCount} messages (no signatures)';
    }

    // Channel selection for server archives
    final selectedChannelId =
        ref.watch(importedArchiveSelectedChannelProvider);
    String? activeChannelId;
    String? activeChannelName;
    if (isServer && data.channels.isNotEmpty) {
      activeChannelId =
          selectedChannelId ?? data.channels.first.channelId;
      activeChannelName = data.channels
              .where((c) => c.channelId == activeChannelId)
              .firstOrNull
              ?.channelName ??
          activeChannelId;
    }

    // Convert messages
    List<ChatMessage>? dmMessages;
    List<ChannelChatMessage>? allChannelMessages;
    List<ChannelChatMessage>? channelMessages;

    if (isDm) {
      dmMessages = convertArchiveDmMessages(data, localPeerId);
    } else {
      allChannelMessages =
          convertArchiveChannelMessages(data, localPeerId);
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

    // Apply sender filter
    final unfilteredChannelMessages = channelMessages;
    if (filterSender != null && channelMessages != null) {
      channelMessages = channelMessages
          .where((m) => m.senderId == filterSender)
          .toList();
    }

    // Unique senders for filter
    final uniqueSenders = unfilteredChannelMessages
        ?.map((m) => m.senderId)
        .toSet()
        .toList()
      ?..sort();
    final senderNames = uniqueSenders != null
        ? {
            for (final id in uniqueSenders)
              id: displayNameFor(profiles, id),
          }
        : <String, String>{};

    // Build edits map
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
    final exporterPeerId = v.exporterPeerId;

    // Header title
    String headerTitle;
    String? headerSubtitle;
    Widget headerLeading;
    if (isDm) {
      headerTitle = displayNameFor(profiles, data.peerId ?? '');
      headerLeading = HollowAvatar(peerId: data.peerId ?? '', size: 24);
    } else if (isServer) {
      headerTitle = activeChannelName ?? 'Channel';
      headerSubtitle = 'in ${data.serverName ?? 'Server'}';
      headerLeading = Text('#',
          style: TextStyle(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 18));
    } else {
      headerTitle = data.channelName ?? 'Channel';
      headerSubtitle =
          data.serverName != null ? 'in ${data.serverName}' : null;
      headerLeading = Text('#',
          style: TextStyle(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 18));
    }

    final visibleMessages =
        isDm ? (dmMessages! as List<dynamic>) : (channelMessages! as List<dynamic>);
    _visibleMessages = visibleMessages;

    return Column(
      children: [
        // Back + title header
        Container(
          height: 52,
          padding:
              const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: [
              HollowPressable(
                onTap: () => Navigator.pop(context),
                semanticLabel: 'Back',
                borderRadius:
                    BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(8),
                child: Icon(LucideIcons.chevronLeft,
                    size: 20, color: hollow.textPrimary),
              ),
              headerLeading,
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: headerSubtitle != null
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(headerTitle,
                              style: HollowTypography.body.copyWith(
                                color: hollow.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          Text(headerSubtitle,
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      )
                    : Text(headerTitle,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
              ),
              if (!isDm &&
                  uniqueSenders != null &&
                  uniqueSenders.length > 1)
                HollowPressable(
                  onTap: () => _showFilterSheet(
                      uniqueSenders, filterSender, senderNames),
                  semanticLabel: 'Filter by sender',
                  borderRadius:
                      BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(6),
                  child: Icon(LucideIcons.filter,
                      size: 16,
                      color: filterSender != null
                          ? hollow.accent
                          : hollow.textSecondary),
                ),
              if (visibleMessages.isNotEmpty)
                HollowPressable(
                  onTap: () {
                    final first = visibleMessages.first is ChatMessage
                        ? (visibleMessages.first as ChatMessage).timestamp
                        : (visibleMessages.first as ChannelChatMessage)
                            .timestamp;
                    final last = visibleMessages.last is ChatMessage
                        ? (visibleMessages.last as ChatMessage).timestamp
                        : (visibleMessages.last as ChannelChatMessage)
                            .timestamp;
                    _pickDate(first, last);
                  },
                  semanticLabel: 'Jump to date',
                  borderRadius:
                      BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(6),
                  child: Icon(LucideIcons.calendar,
                      size: 16, color: hollow.textSecondary),
                ),
              HollowPressable(
                onTap: _toggleSearch,
                semanticLabel: 'Search messages',
                borderRadius:
                    BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(6),
                child: Icon(LucideIcons.search,
                    size: 16,
                    color: searchOpen
                        ? hollow.accent
                        : hollow.textSecondary),
              ),
              Container(
                margin: const EdgeInsets.only(left: 4, right: 4),
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius:
                      BorderRadius.circular(hollow.radiusSm),
                ),
                child: Text('read-only',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 9,
                    )),
              ),
            ],
          ),
        ),

        // Verification banner
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md, vertical: 8),
          decoration: BoxDecoration(
            color: archiveColor.withValues(alpha: 0.08),
            border: Border(
                bottom: BorderSide(
                    color: hollow.border.withValues(alpha: 0.3))),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(archiveIcon, size: 13, color: archiveColor),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(archiveText,
                        style: HollowTypography.caption.copyWith(
                          color: archiveColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Row(
                children: [
                  Icon(msgIcon, size: 13, color: msgColor),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(msgText,
                        style: HollowTypography.caption.copyWith(
                          color: msgColor,
                          fontSize: 10,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Channel selector for server archives
        if (isServer && data.channels.length > 1)
          Container(
            height: 36,
            padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              border:
                  Border(bottom: BorderSide(color: hollow.border)),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: data.channels.map((ch) {
                final isActive = ch.channelId == activeChannelId;
                return Padding(
                  padding: const EdgeInsets.only(
                      right: HollowSpacing.xs),
                  child: Center(
                    child: HollowPressable(
                      onTap: () {
                        ref
                            .read(importedArchiveSelectedChannelProvider
                                .notifier)
                            .state = ch.channelId;
                        ref
                            .read(
                                archiveFilterSenderProvider.notifier)
                            .state = null;
                        ref
                            .read(archiveMessageSearchQueryProvider
                                .notifier)
                            .state = '';
                        ref
                            .read(archiveSearchMatchIndexProvider
                                .notifier)
                            .state = 0;
                      },
                      borderRadius:
                          BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      child: Container(
                        decoration: BoxDecoration(
                          color: isActive
                              ? hollow.accent
                                  .withValues(alpha: 0.15)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(
                              hollow.radiusSm),
                          border: Border.all(
                            color: isActive
                                ? hollow.accent
                                    .withValues(alpha: 0.3)
                                : hollow.border,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        child: Text(
                          '# ${ch.channelName}',
                          style:
                              HollowTypography.caption.copyWith(
                            color: isActive
                                ? hollow.accent
                                : hollow.textSecondary,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.normal,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

        // Search bar
        if (searchOpen) _buildSearchBar(visibleMessages),

        // Message list
        Expanded(
          child: visibleMessages.isEmpty
              ? Center(
                  child: Text('No messages',
                      style: HollowTypography.body
                          .copyWith(color: hollow.textSecondary)),
                )
              : isDm
                  ? _buildDmMessageList(
                      dmMessages!, profiles, localPeerId, data, editsMap,
                      proofContext, proofMsgType, exporterPeerId)
                  : _buildChannelMessageList(
                      channelMessages!,
                      unfilteredChannelMessages ?? channelMessages,
                      profiles, editsMap, proofContext, proofMsgType),
        ),
      ],
    );
  }

  Widget _buildDmMessageList(
    List<ChatMessage> messages,
    Map<String, storage_api.UserProfile> profiles,
    String localPeerId,
    archive_api.ArchiveData data,
    Map<String, List<ArchiveEditEntry>> editsMap,
    String proofContext,
    String proofMsgType,
    String exporterPeerId,
  ) {
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
                : displayNameFor(profiles, data.peerId ?? '');
          }
        }

        final isCurrentMatch = matchIndices.isNotEmpty &&
            matchIdx < matchIndices.length &&
            matchIndices[matchIdx] == index;

        final senderPeerId =
            msg.isMe ? localPeerId : (data.peerId ?? '');

        Widget bubble = MessageBubble(
          message: msg,
          peerId: data.peerId ?? '',
          showHeader: showHeader,
          replyToText: replyToText,
          replyToSenderName: replyToSenderName,
          isHighlighted: _highlightIndex == index || isCurrentMatch,
          onReplyTap: null,
          onToggleReaction: null,
        );

        if (msg.hiddenAt != null) {
          bubble =
              _DeletedOverlay(hiddenAt: msg.hiddenAt!, child: bubble);
        }

        final msgEdits =
            msg.messageId != null ? editsMap[msg.messageId] : null;

        final dmProofCtx = proofMsgType == 'dm'
            ? (senderPeerId == exporterPeerId ? proofContext : exporterPeerId)
            : proofContext;

        if (msgEdits != null && msgEdits.isNotEmpty) {
          bubble = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bubble,
              EditHistoryIndicator(
                edits: msgEdits,
                senderPeerId: senderPeerId,
                proofContext: dmProofCtx,
                proofMsgType: proofMsgType,
                messageId: msg.messageId,
              ),
            ],
          );
        }

        bubble = _LongPressMessage(
          onLongPress: () => _showActions(
            msg.text,
            displayNameFor(profiles, senderPeerId),
            msg.timestamp,
            senderPeerId,
            msg.signature,
            msg.publicKey,
            msg.messageId,
            msg.editedAt,
            dmProofCtx,
            proofMsgType,
            msg.fileAttachment,
            profiles,
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

  Widget _buildChannelMessageList(
    List<ChannelChatMessage> messages,
    List<ChannelChatMessage> allMessages,
    Map<String, storage_api.UserProfile> profiles,
    Map<String, List<ArchiveEditEntry>> editsMap,
    String proofContext,
    String proofMsgType,
  ) {
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
          serverId: proofContext.split(':').first,
          showHeader: showHeader,
          replyToText: replyToText,
          replyToSenderName: replyToSenderName,
          isHighlighted: _highlightIndex == index || isCurrentMatch,
          onReplyTap: null,
          onToggleReaction: null,
        );

        if (msg.hiddenAt != null) {
          bubble =
              _DeletedOverlay(hiddenAt: msg.hiddenAt!, child: bubble);
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
                proofContext: proofContext,
                proofMsgType: proofMsgType,
                messageId: msg.messageId,
              ),
            ],
          );
        }

        bubble = _LongPressMessage(
          onLongPress: () => _showActions(
            msg.text,
            displayNameFor(profiles, msg.senderId),
            msg.timestamp,
            msg.senderId,
            msg.signature,
            msg.publicKey,
            msg.messageId,
            msg.editedAt,
            proofContext,
            proofMsgType,
            msg.fileAttachment,
            profiles,
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

  // ── Shared helpers ─────────────────────────────────────────────

  void _showActions(
    String text,
    String senderName,
    DateTime timestamp,
    String senderPeerId,
    String? signature,
    String? publicKey,
    String? messageId,
    DateTime? editedAt,
    String proofContext,
    String proofMsgType,
    FileAttachment? fileAttachment,
    Map<String, storage_api.UserProfile> profiles,
  ) {
    final time =
        '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}';
    showMobileArchiveMessageActions(
      context: context,
      messageText: text,
      senderName: senderName,
      timestamp: time,
      onCopy: text.isNotEmpty && !text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload:
          fileAttachment != null && fileAttachment.diskPath != null
              ? () => _saveFile(fileAttachment)
              : null,
      onInfo: messageId != null
          ? () {
              showMessageProofDialog(
                context,
                MessageProofData(
                  senderPeerId: senderPeerId,
                  senderDisplayName:
                      displayNameFor(profiles, senderPeerId),
                  text: text,
                  timestampMs: (editedAt ?? timestamp)
                      .millisecondsSinceEpoch,
                  signature: signature,
                  publicKey: publicKey,
                  messageId: messageId,
                  context: proofContext,
                  msgType: proofMsgType,
                  fileAttachment: fileAttachment,
                ),
              );
            }
          : null,
    );
  }

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
              final prev = (matchIdx - 1 + matchIndices.length) %
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
                  Text('All participants',
                      style: HollowTypography.body.copyWith(
                        color: widget.selectedSender == null
                            ? hollow.accent
                            : hollow.textPrimary,
                        fontWeight: widget.selectedSender == null
                            ? FontWeight.w600
                            : FontWeight.normal,
                        fontSize: 14,
                      )),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: hollow.border),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight:
                  MediaQuery.of(context).size.height * 0.4,
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(
                  vertical: HollowSpacing.xs),
              itemCount: filtered.length,
              itemBuilder: (_, index) {
                final id = filtered[index];
                final name =
                    widget.senderNames[id] ?? id.substring(0, 8);
                final isActive = widget.selectedSender == id;
                return HollowPressable(
                  onTap: () {
                    Navigator.pop(context);
                    widget.onSelected(id);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.lg, vertical: 8),
                    child: Row(
                      children: [
                        HollowAvatar(peerId: id, size: 24),
                        const SizedBox(width: HollowSpacing.sm),
                        Expanded(
                          child: Text(name,
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
                              overflow: TextOverflow.ellipsis),
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

// ── Deleted overlay ────────────────────────────────────────────

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
                Text('Deleted at $time',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.error.withValues(alpha: 0.7),
                      fontSize: 10,
                      fontStyle: FontStyle.italic,
                    )),
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

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/shared/archive_shared_widgets.dart';
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart'
    show shouldGroup, shouldShowDateSeparator, DateSeparator;
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Wraps a rendered message with platform actions (desktop: MessageHoverWrapper,
/// mobile: LongPressMessage). `context` is the itemBuilder's element —
/// callbacks that show toasts/dialogs must guard THIS context, not the State's.
typedef ArchiveActionWrapper<T> = Widget Function(
    BuildContext context, T message, Widget child);

Duration _defaultArchiveScrollDuration() => const Duration(milliseconds: 300);

/// Lets an externally rendered search bar (mobile) drive the list's
/// scroll-to-match + highlight. Bound by the list core while mounted.
class ArchiveMessageListController {
  void Function(int index)? _scrollToIndex;

  void scrollToIndex(int index) => _scrollToIndex?.call(index);
}

List<int> _searchMatchIndices(
    int length, String Function(int index) textAt, String query) {
  final matchIndices = <int>[];
  if (query.isNotEmpty) {
    final q = query.toLowerCase();
    for (int i = 0; i < length; i++) {
      if (textAt(i).toLowerCase().contains(q)) {
        matchIndices.add(i);
      }
    }
  }
  return matchIndices;
}

Widget _archiveSearchRow(WidgetRef ref, List<int> matchIndices, int matchIdx,
    void Function(int index) scrollToIndex) {
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
            ref.read(archiveSearchMatchIndexProvider.notifier).state = next;
            scrollToIndex(matchIndices[next]);
          }
        : null,
    onPrev: matchIndices.isNotEmpty
        ? () {
            final prev =
                (matchIdx - 1 + matchIndices.length) % matchIndices.length;
            ref.read(archiveSearchMatchIndexProvider.notifier).state = prev;
            scrollToIndex(matchIndices[prev]);
          }
        : null,
    onClose: () {
      ref.read(archiveMessageSearchOpenProvider.notifier).state = false;
      ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
      ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
    },
  );
}

/// Search bar rendered OUTSIDE the list (mobile viewers keep it above the
/// loading/empty states). Computes matches over [texts] and scrolls the bound
/// list via [controller].
class ArchiveListSearchBar extends ConsumerWidget {
  final List<String> texts;
  final ArchiveMessageListController controller;

  const ArchiveListSearchBar({
    super.key,
    required this.texts,
    required this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchQuery = ref.watch(archiveMessageSearchQueryProvider);
    final matchIdx = ref.watch(archiveSearchMatchIndexProvider);
    final matchIndices =
        _searchMatchIndices(texts.length, (i) => texts[i], searchQuery);
    return _archiveSearchRow(
        ref, matchIndices, matchIdx, controller.scrollToIndex);
  }
}

// ── Public DM / channel lists ───────────────────────────────────

/// Read-only DM archive message list (MessageBubble rows, isMe grouping).
class ArchiveDmMessageList extends ConsumerWidget {
  final List<ChatMessage> messages;
  final String peerId;
  final String localPeerId;
  final Map<String, List<ArchiveEditEntry>> editsMap;
  /// Proof context for the edit-history indicator. Direction- and
  /// source-dependent (live: isMe ? peerId : localPeerId; imported:
  /// exporter-relative) — always computed at call sites.
  final String Function(ChatMessage msg) proofContextFor;
  final String proofMsgType;
  final ArchiveActionWrapper<ChatMessage> actionWrapper;
  /// Desktop: MessageActionBarScope + SelectionArea + inline search bar.
  final bool desktopChrome;
  final Duration Function() scrollDuration;
  final ArchiveMessageListController? controller;

  const ArchiveDmMessageList({
    super.key,
    required this.messages,
    required this.peerId,
    required this.localPeerId,
    required this.editsMap,
    required this.proofContextFor,
    this.proofMsgType = 'dm',
    required this.actionWrapper,
    this.desktopChrome = false,
    this.scrollDuration = _defaultArchiveScrollDuration,
    this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profileProvider);

    return _ArchiveMessageListCore<ChatMessage>(
      messages: messages,
      timestampOf: (m) => m.timestamp,
      textOf: (m) => m.text,
      hiddenAtOf: (m) => m.hiddenAt,
      messageIdOf: (m) => m.messageId,
      groupsWith: (msg, prev) => shouldGroup(
        currentIsMe: msg.isMe,
        previousIsMe: prev.isMe,
        currentTime: msg.timestamp,
        previousTime: prev.timestamp,
      ),
      replyPreviewFor: (msg) {
        if (msg.replyToMid == null) return null;
        final replyMsg =
            messages.where((m) => m.messageId == msg.replyToMid).firstOrNull;
        if (replyMsg == null) return null;
        final text = replyMsg.fileAttachment != null
            ? (replyMsg.fileAttachment!.isImage
                ? '\u{1F4F7} Image'
                : '\u{1F4CE} ${replyMsg.fileAttachment!.fileName}')
            : replyMsg.text;
        final senderName = replyMsg.isMe
            ? displayNameFor(profiles, localPeerId)
            : displayNameFor(profiles, peerId);
        return (text, senderName);
      },
      bubbleBuilder:
          (msg, showHeader, replyToText, replyToSenderName, isHighlighted) =>
              MessageBubble(
        message: msg,
        peerId: peerId,
        showHeader: showHeader,
        replyToText: replyToText,
        replyToSenderName: replyToSenderName,
        isHighlighted: isHighlighted,
        onReplyTap: null,
        onToggleReaction: null,
      ),
      editsMap: editsMap,
      editSenderPeerIdOf: (msg) => msg.isMe ? localPeerId : peerId,
      editProofContextOf: proofContextFor,
      proofMsgType: proofMsgType,
      actionWrapper: actionWrapper,
      desktopChrome: desktopChrome,
      scrollDuration: scrollDuration,
      controller: controller,
    );
  }
}

/// Read-only channel archive message list (ChannelMessageBubble rows,
/// sender-id grouping, reply lookup in the unfiltered [allMessages]).
class ArchiveChannelMessageList extends ConsumerWidget {
  final List<ChannelChatMessage> messages;
  /// Full unfiltered list for reply lookups when a sender filter is active.
  final List<ChannelChatMessage> allMessages;
  final String serverId;
  final Map<String, List<ArchiveEditEntry>> editsMap;
  final String proofContext;
  final String proofMsgType;
  final ArchiveActionWrapper<ChannelChatMessage> actionWrapper;
  /// Desktop: MessageActionBarScope + SelectionArea + inline search bar.
  final bool desktopChrome;
  final Duration Function() scrollDuration;
  final ArchiveMessageListController? controller;

  const ArchiveChannelMessageList({
    super.key,
    required this.messages,
    required this.allMessages,
    required this.serverId,
    required this.editsMap,
    required this.proofContext,
    this.proofMsgType = 'ch',
    required this.actionWrapper,
    this.desktopChrome = false,
    this.scrollDuration = _defaultArchiveScrollDuration,
    this.controller,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profileProvider);

    return _ArchiveMessageListCore<ChannelChatMessage>(
      messages: messages,
      timestampOf: (m) => m.timestamp,
      textOf: (m) => m.text,
      hiddenAtOf: (m) => m.hiddenAt,
      messageIdOf: (m) => m.messageId,
      groupsWith: (msg, prev) => shouldGroup(
        currentIsMe: msg.isMe,
        previousIsMe: prev.isMe,
        currentTime: msg.timestamp,
        previousTime: prev.timestamp,
        currentSenderId: msg.senderId,
        previousSenderId: prev.senderId,
      ),
      replyPreviewFor: (msg) {
        if (msg.replyToMid == null) return null;
        final replyMsg = allMessages
            .where((m) => m.messageId == msg.replyToMid)
            .firstOrNull;
        if (replyMsg == null) return null;
        final text = replyMsg.fileAttachment != null
            ? (replyMsg.fileAttachment!.isImage
                ? '\u{1F4F7} Image'
                : '\u{1F4CE} ${replyMsg.fileAttachment!.fileName}')
            : replyMsg.text;
        return (text, displayNameFor(profiles, replyMsg.senderId));
      },
      bubbleBuilder:
          (msg, showHeader, replyToText, replyToSenderName, isHighlighted) =>
              ChannelMessageBubble(
        message: msg,
        serverId: serverId,
        showHeader: showHeader,
        replyToText: replyToText,
        replyToSenderName: replyToSenderName,
        isHighlighted: isHighlighted,
        onReplyTap: null,
        onToggleReaction: null,
      ),
      editsMap: editsMap,
      editSenderPeerIdOf: (msg) => msg.senderId,
      editProofContextOf: (_) => proofContext,
      proofMsgType: proofMsgType,
      actionWrapper: actionWrapper,
      desktopChrome: desktopChrome,
      scrollDuration: scrollDuration,
      controller: controller,
    );
  }
}

// ── Shared core ─────────────────────────────────────────────────

class _ArchiveMessageListCore<T> extends ConsumerStatefulWidget {
  final List<T> messages;
  final DateTime Function(T msg) timestampOf;
  final String Function(T msg) textOf;
  final DateTime? Function(T msg) hiddenAtOf;
  final String? Function(T msg) messageIdOf;
  final bool Function(T msg, T prev) groupsWith;
  final (String, String)? Function(T msg) replyPreviewFor;
  final Widget Function(T msg, bool showHeader, String? replyToText,
      String? replyToSenderName, bool isHighlighted) bubbleBuilder;
  final Map<String, List<ArchiveEditEntry>> editsMap;
  final String Function(T msg) editSenderPeerIdOf;
  final String Function(T msg) editProofContextOf;
  final String proofMsgType;
  final ArchiveActionWrapper<T> actionWrapper;
  final bool desktopChrome;
  final Duration Function() scrollDuration;
  final ArchiveMessageListController? controller;

  const _ArchiveMessageListCore({
    required this.messages,
    required this.timestampOf,
    required this.textOf,
    required this.hiddenAtOf,
    required this.messageIdOf,
    required this.groupsWith,
    required this.replyPreviewFor,
    required this.bubbleBuilder,
    required this.editsMap,
    required this.editSenderPeerIdOf,
    required this.editProofContextOf,
    required this.proofMsgType,
    required this.actionWrapper,
    required this.desktopChrome,
    required this.scrollDuration,
    this.controller,
  });

  @override
  ConsumerState<_ArchiveMessageListCore<T>> createState() =>
      _ArchiveMessageListCoreState<T>();
}

class _ArchiveMessageListCoreState<T>
    extends ConsumerState<_ArchiveMessageListCore<T>> {
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  int? _highlightIndex;

  @override
  void initState() {
    super.initState();
    widget.controller?._scrollToIndex = _scrollToIndex;
  }

  @override
  void didUpdateWidget(covariant _ArchiveMessageListCore<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller?._scrollToIndex = null;
      widget.controller?._scrollToIndex = _scrollToIndex;
    }
  }

  @override
  void dispose() {
    widget.controller?._scrollToIndex = null;
    super.dispose();
  }

  void _jumpToDate(DateTime target) {
    final targetStart = DateTime(target.year, target.month, target.day);
    int lo = 0, hi = widget.messages.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (widget.timestampOf(widget.messages[mid]).isBefore(targetStart)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < widget.messages.length && _itemScrollController.isAttached) {
      _itemScrollController.scrollTo(
        index: lo,
        duration: widget.scrollDuration(),
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
      duration: widget.scrollDuration(),
      curve: Curves.easeOutCubic,
      alignment: 0.3,
    );
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _highlightIndex = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    // ref.listen is only valid during build (an initState registration is
    // rejected by Riverpod, silently breaking jump-to-date).
    ref.listen(archiveJumpToDateProvider, (_, date) {
      if (date != null && widget.messages.isNotEmpty) {
        _jumpToDate(date);
        ref.read(archiveJumpToDateProvider.notifier).state = null;
      }
    });

    final hollow = HollowTheme.of(context);
    final messages = widget.messages;
    final searchQuery = ref.watch(archiveMessageSearchQueryProvider);
    final matchIdx = ref.watch(archiveSearchMatchIndexProvider);

    final matchIndices = _searchMatchIndices(
        messages.length, (i) => widget.textOf(messages[i]), searchQuery);

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary)),
      );
    }

    // Reading surface: honours the chat text size like the live panes do.
    final Widget list = ChatTextScale(
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
            widget.timestampOf(msg),
            prev != null ? widget.timestampOf(prev) : null,
          );

          final showHeader =
              prev == null || showDate || !widget.groupsWith(msg, prev);

          final reply = widget.replyPreviewFor(msg);

          final isCurrentMatch = matchIndices.isNotEmpty &&
              matchIdx < matchIndices.length &&
              matchIndices[matchIdx] == index;

          Widget bubble = widget.bubbleBuilder(msg, showHeader, reply?.$1,
              reply?.$2, _highlightIndex == index || isCurrentMatch);

          // Deleted message overlay.
          final hiddenAt = widget.hiddenAtOf(msg);
          if (hiddenAt != null) {
            bubble = ArchiveDeletedOverlay(hiddenAt: hiddenAt, child: bubble);
          }

          // Edit history indicator.
          final messageId = widget.messageIdOf(msg);
          final msgEdits = messageId != null ? widget.editsMap[messageId] : null;
          if (msgEdits != null && msgEdits.isNotEmpty) {
            bubble = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bubble,
                EditHistoryIndicator(
                  edits: msgEdits,
                  senderPeerId: widget.editSenderPeerIdOf(msg),
                  proofContext: widget.editProofContextOf(msg),
                  proofMsgType: widget.proofMsgType,
                  messageId: messageId,
                ),
              ],
            );
          }

          // Platform action wrapper (hover actions / long-press).
          bubble = widget.actionWrapper(context, msg, bubble);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDate) DateSeparator(date: widget.timestampOf(msg)),
              bubble,
            ],
          );
        },
      ),
    );

    if (!widget.desktopChrome) return list;

    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    return Column(
      children: [
        if (searchOpen)
          _archiveSearchRow(ref, matchIndices, matchIdx, _scrollToIndex),
        Expanded(
          child: MessageActionBarScope(
            child: Builder(
              builder: (scopeContext) =>
                  NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is ScrollUpdateNotification) {
                    MessageActionBarScope.of(scopeContext)?.dismissAll();
                  }
                  return false;
                },
                child: SelectionArea(
                  contextMenuBuilder: (_, _) => const SizedBox.shrink(),
                  child: list,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

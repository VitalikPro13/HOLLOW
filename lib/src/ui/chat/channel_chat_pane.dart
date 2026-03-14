import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/channel_chat_provider.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/member_panel_provider.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/core/providers/sync_progress_provider.dart';
import 'package:haven/src/core/providers/typing_provider.dart';
import 'package:haven/src/core/providers/pinned_provider.dart';
import 'package:haven/src/rust/api/crdt.dart' as crdt_api;
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/chat/channel_message_bubble.dart';
import 'package:haven/src/ui/chat/chat_input_shortcuts.dart';
import 'package:haven/src/ui/chat/chat_pane.dart';
import 'package:haven/src/ui/chat/message_action_bar.dart';
import 'package:haven/src/ui/components/connection_progress.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:haven/src/rust/api/storage.dart' as storage_api;
import 'package:lucide_icons/lucide_icons.dart';

class ChannelChatPane extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  const ChannelChatPane({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
  });

  @override
  ConsumerState<ChannelChatPane> createState() => _ChannelChatPaneState();
}

class _ChannelChatPaneState extends ConsumerState<ChannelChatPane> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  bool _historyLoaded = false;
  int _previousMessageCount = 0;
  String? _editingMessageId;
  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  DateTime? _lastTypingSent;
  bool _searchOpen = false;
  final _searchController = TextEditingController();
  List<dynamic> _searchResults = [];

  String get _stateKey => '${widget.serverId}:${widget.channelId}';

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    await ref
        .read(channelChatProvider.notifier)
        .loadHistory(widget.serverId, widget.channelId);
    ref.read(pinnedProvider.notifier).loadPins(widget.serverId, widget.channelId);
    _jumpToBottom();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  /// Instant jump — no animation.
  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  /// Smooth scroll for new incoming messages.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showPinnedMessages(
    BuildContext context,
    HavenTheme haven,
    List<String> pinnedIds,
  ) {
    final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
    final pinnedMessages = pinnedIds
        .map((id) => messages.where((m) => m.messageId == id).firstOrNull)
        .where((m) => m != null)
        .toList();

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: haven.elevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(haven.radiusLg),
          side: BorderSide(color: haven.border),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 400),
          child: Padding(
            padding: const EdgeInsets.all(HavenSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.pin, size: 18, color: haven.accent),
                    const SizedBox(width: HavenSpacing.sm),
                    Text(
                      'Pinned Messages',
                      style: HavenTypography.subheading.copyWith(
                        color: haven.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    HavenPressable(
                      onTap: () => Navigator.pop(ctx),
                      padding: const EdgeInsets.all(4),
                      child: Icon(LucideIcons.x, size: 16, color: haven.textSecondary),
                    ),
                  ],
                ),
                const SizedBox(height: HavenSpacing.md),
                if (pinnedMessages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: HavenSpacing.xl),
                    child: Center(
                      child: Text(
                        'Pinned messages not loaded in current view.',
                        style: HavenTypography.body.copyWith(
                          color: haven.textSecondary,
                        ),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: pinnedMessages.length,
                      separatorBuilder: (_, _) => Divider(
                        color: haven.border,
                        height: HavenSpacing.md,
                      ),
                      itemBuilder: (_, index) {
                        final msg = pinnedMessages[index]!;
                        final profiles = ref.read(profileProvider);
                        final nicknames =
                            ref.read(serverNicknamesProvider(widget.serverId));
                        final name = serverDisplayNameFor(
                          profiles,
                          msg.senderId,
                          nickname: nicknames[msg.senderId] ?? '',
                        );
                        final time =
                            '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}';
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: HavenSpacing.xs),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    name,
                                    style: HavenTypography.body.copyWith(
                                      color: haven.accent,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: HavenSpacing.sm),
                                  Text(
                                    time,
                                    style: HavenTypography.caption.copyWith(
                                      color: haven.textSecondary
                                          .withValues(alpha: 0.5),
                                      fontSize: 10,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                msg.text,
                                style: HavenTypography.body.copyWith(
                                  color: haven.textPrimary,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
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

  Future<void> _onSearch(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    try {
      final results = await storage_api.searchChannelMessages(
        serverId: widget.serverId,
        channelId: widget.channelId,
        query: query.trim(),
        limit: 20,
      );
      if (mounted) setState(() => _searchResults = results);
    } catch (_) {}
  }

  void _onTextChanged(String text) {
    if (text.isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingSent != null &&
        now.difference(_lastTypingSent!).inSeconds < 3) {
      return;
    }
    _lastTypingSent = now;
    try {
      network_api.sendTypingIndicator(
        serverId: widget.serverId,
        channelId: widget.channelId,
      );
    } catch (_) {}
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    _lastTypingSent = null;
    _focusNode.requestFocus();
    final replyMid = _replyToMessageId;
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
    });
    await ref
        .read(channelChatProvider.notifier)
        .sendMessage(widget.serverId, widget.channelId, text,
            replyToMid: replyMid);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final chatState = ref.watch(channelChatProvider);
    final messages = chatState[_stateKey] ?? [];

    // Auto-scroll when new messages arrive and user is near the bottom.
    if (messages.length > _previousMessageCount && _isNearBottom) {
      _scrollToBottom();
    }
    _previousMessageCount = messages.length;

    final typingPeers = ref.watch(typingProvider)[_stateKey] ?? {};

    return Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
          decoration: BoxDecoration(
            color: haven.surface,
            border: Border(bottom: BorderSide(color: haven.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.hash, size: 20, color: haven.textSecondary),
              const SizedBox(width: HavenSpacing.sm),
              Text(
                widget.channelName,
                style: HavenTypography.subheading.copyWith(
                  color: haven.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: HavenSpacing.md),
              _ChannelConnectionStatus(
                serverId: widget.serverId,
                channelId: widget.channelId,
              ),
              const Spacer(),
              Builder(builder: (context) {
                final pinKey = '${widget.serverId}:${widget.channelId}';
                final pinnedIds = ref.watch(pinnedProvider)[pinKey] ?? [];
                if (pinnedIds.isEmpty) return const SizedBox.shrink();
                return HavenTooltip(
                  message: '${pinnedIds.length} pinned message${pinnedIds.length == 1 ? '' : 's'}',
                  child: HavenPressable(
                    onTap: () => _showPinnedMessages(context, haven, pinnedIds),
                    borderRadius: BorderRadius.circular(haven.radiusSm),
                    padding: const EdgeInsets.all(HavenSpacing.xs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.pin, size: 16, color: haven.accent),
                        const SizedBox(width: 2),
                        Text(
                          '${pinnedIds.length}',
                          style: HavenTypography.caption.copyWith(
                            color: haven.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(width: HavenSpacing.sm),
              HavenTooltip(
                message: 'Search messages',
                child: HavenPressable(
                  onTap: () => setState(() => _searchOpen = !_searchOpen),
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(
                    LucideIcons.search,
                    size: 18,
                    color: _searchOpen ? haven.accent : haven.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: HavenSpacing.sm),
              HavenTooltip(
                message: 'Toggle member panel',
                child: HavenPressable(
                  onTap: () => ref.read(memberPanelProvider.notifier).state =
                      !ref.read(memberPanelProvider),
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(
                    LucideIcons.users,
                    size: 20,
                    color: ref.watch(memberPanelProvider)
                        ? haven.accent
                        : haven.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Search bar
        if (_searchOpen)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HavenSpacing.md,
              vertical: HavenSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: haven.surface,
              border: Border(bottom: BorderSide(color: haven.border)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HavenTextField(
                  controller: _searchController,
                  hintText: 'Search in #${widget.channelName}...',
                  autofocus: true,
                  isDense: true,
                  prefixIcon: Icon(LucideIcons.search, size: 16),
                  onChanged: _onSearch,
                  style: HavenTypography.body.copyWith(
                    color: haven.textPrimary,
                    fontSize: 13,
                  ),
                ),
                if (_searchResults.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      itemBuilder: (_, index) {
                        final msg = _searchResults[index];
                        final profiles = ref.watch(profileProvider);
                        final nicknames = ref.watch(
                            serverNicknamesProvider(widget.serverId));
                        final name = serverDisplayNameFor(
                          profiles,
                          msg.senderId,
                          nickname: nicknames[msg.senderId] ?? '',
                        );
                        final time = DateTime.fromMillisecondsSinceEpoch(
                            msg.timestamp);
                        final timeStr =
                            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
                        return Padding(
                          padding: const EdgeInsets.only(
                              top: HavenSpacing.xs),
                          child: HavenPressable(
                            subtle: true,
                            onTap: () {
                              setState(() {
                                _searchOpen = false;
                                _searchController.clear();
                                _searchResults = [];
                              });
                            },
                            borderRadius:
                                BorderRadius.circular(haven.radiusSm),
                            hoverColor: haven.elevated,
                            padding: const EdgeInsets.symmetric(
                              horizontal: HavenSpacing.sm,
                              vertical: HavenSpacing.xs,
                            ),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      name,
                                      style: HavenTypography.caption
                                          .copyWith(
                                        color: haven.accent,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 11,
                                      ),
                                    ),
                                    const SizedBox(
                                        width: HavenSpacing.sm),
                                    Text(
                                      timeStr,
                                      style: HavenTypography.caption
                                          .copyWith(
                                        color: haven.textSecondary
                                            .withValues(alpha: 0.5),
                                        fontSize: 10,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  msg.text,
                                  style: HavenTypography.body.copyWith(
                                    color: haven.textPrimary,
                                    fontSize: 12,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),

        // Messages list
        Expanded(
          child: MessageActionBarScope(
          child: Container(
            color: haven.background,
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.hash,
                          size: 64,
                          color:
                              haven.textSecondary.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: HavenSpacing.lg),
                        Text(
                          'Welcome to #${widget.channelName}',
                          style: HavenTypography.heading
                              .copyWith(color: haven.textPrimary),
                        ),
                        const SizedBox(height: HavenSpacing.sm),
                        Text(
                          'This is the beginning of the channel.',
                          style: HavenTypography.body
                              .copyWith(color: haven.textSecondary),
                        ),
                      ],
                    ),
                  )
                : ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(scrollbars: false),
                    child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                      vertical: HavenSpacing.sm,
                    ),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      final showHeader = index == 0 ||
                          !shouldGroup(
                            currentIsMe: msg.isMe,
                            previousIsMe: messages[index - 1].isMe,
                            currentTime: msg.timestamp,
                            previousTime: messages[index - 1].timestamp,
                            currentSenderId: msg.senderId,
                            previousSenderId: messages[index - 1].senderId,
                          );
                      final profiles = ref.watch(profileProvider);
                      final nicknames = ref.watch(serverNicknamesProvider(widget.serverId));
                      final wrapper = MessageHoverWrapper(
                        isMe: msg.isMe,
                        messageId: msg.messageId,
                        currentText: msg.text,
                        isEditing: _editingMessageId != null &&
                            _editingMessageId == msg.messageId,
                        onEditStart: msg.messageId != null && msg.isMe
                            ? () => setState(() =>
                                _editingMessageId = msg.messageId)
                            : null,
                        onEditSubmit: (newText) {
                          setState(() => _editingMessageId = null);
                          ref
                              .read(channelChatProvider.notifier)
                              .editMessage(widget.serverId, widget.channelId,
                                  msg.messageId!, newText);
                        },
                        onEditCancel: () =>
                            setState(() => _editingMessageId = null),
                        onDelete: msg.messageId != null && msg.isMe
                            ? () => ref
                                .read(channelChatProvider.notifier)
                                .deleteMessage(widget.serverId,
                                    widget.channelId, msg.messageId!)
                            : null,
                        onReply: msg.messageId != null
                            ? () {
                                final senderName = serverDisplayNameFor(
                                  profiles,
                                  msg.senderId,
                                  nickname: nicknames[msg.senderId] ?? '',
                                );
                                setState(() {
                                  _replyToMessageId = msg.messageId;
                                  _replyToText = msg.text;
                                  _replyToSenderName = senderName;
                                });
                                _focusNode.requestFocus();
                              }
                            : null,
                        onReaction: msg.messageId != null
                            ? (emoji) {
                                final localPeerId =
                                    ref.read(identityProvider).peerId ?? '';
                                final hasReacted =
                                    msg.reactions[emoji]?.contains(localPeerId) ?? false;
                                final notifier = ref.read(channelChatProvider.notifier);
                                if (hasReacted) {
                                  notifier.removeReaction(widget.serverId,
                                      widget.channelId, msg.messageId!, emoji);
                                } else {
                                  notifier.addReaction(widget.serverId,
                                      widget.channelId, msg.messageId!, emoji);
                                }
                              }
                            : null,
                        onPin: msg.messageId != null &&
                                (ref.watch(myPermissionsProvider(widget.serverId)).whenOrNull(
                                    data: (perms) => (perms & Permission.manageChannels) != 0) ?? false)
                            ? () {
                                final pins = ref.read(pinnedProvider)[
                                    '${widget.serverId}:${widget.channelId}'] ?? [];
                                if (pins.contains(msg.messageId)) {
                                  crdt_api.unpinMessage(
                                    serverId: widget.serverId,
                                    channelId: widget.channelId,
                                    messageId: msg.messageId!,
                                  );
                                } else {
                                  crdt_api.pinMessage(
                                    serverId: widget.serverId,
                                    channelId: widget.channelId,
                                    messageId: msg.messageId!,
                                  );
                                }
                              }
                            : null,
                        child: Builder(builder: (_) {
                          final localPeerId =
                              ref.watch(identityProvider).peerId ?? '';
                          String? replySender;
                          String? replyText;
                          if (msg.replyToMid != null) {
                            final idx = messages.indexWhere(
                                (m) => m.messageId == msg.replyToMid);
                            if (idx != -1) {
                              final original = messages[idx];
                              replyText = original.text;
                              replySender = serverDisplayNameFor(
                                profiles,
                                original.senderId,
                                nickname: nicknames[original.senderId] ?? '',
                              );
                            }
                          }
                          return ChannelMessageBubble(
                            message: msg,
                            serverId: widget.serverId,
                            showHeader: showHeader,
                            replyToSenderName: replySender,
                            replyToText: replyText,
                            onToggleReaction: msg.messageId != null
                                ? (emoji) {
                                    final hasReacted =
                                        msg.reactions[emoji]?.contains(localPeerId) ?? false;
                                    final notifier = ref.read(channelChatProvider.notifier);
                                    if (hasReacted) {
                                      notifier.removeReaction(widget.serverId,
                                          widget.channelId, msg.messageId!, emoji);
                                    } else {
                                      notifier.addReaction(widget.serverId,
                                          widget.channelId, msg.messageId!, emoji);
                                    }
                                  }
                                : null,
                          );
                        }),
                      );
                      if (showHeader) {
                        return Padding(
                          padding: const EdgeInsets.only(top: HavenSpacing.sm + 2),
                          child: wrapper,
                        );
                      }
                      return wrapper;
                    },
                  ),
                  ),
          ),
          ),
        ),

        // Typing indicator
        if (typingPeers.isNotEmpty)
          TypingIndicatorBar(
            names: typingPeers
                .map((pid) {
                  final nicknames =
                      ref.watch(serverNicknamesProvider(widget.serverId));
                  return serverDisplayNameFor(
                    ref.watch(profileProvider),
                    pid,
                    nickname: nicknames[pid] ?? '',
                  );
                })
                .toList(),
          ),

        // Reply preview bar
        if (_replyToMessageId != null)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HavenSpacing.md,
              vertical: HavenSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: haven.surface,
              border: Border(
                top: BorderSide(color: haven.border),
                left: BorderSide(color: haven.accent, width: 3),
              ),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.reply, size: 14, color: haven.accent),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Replying to ${_replyToSenderName ?? ''}',
                        style: HavenTypography.caption.copyWith(
                          color: haven.accent,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                      ),
                      Text(
                        _replyToText ?? '',
                        style: HavenTypography.body.copyWith(
                          color: haven.textSecondary,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                HavenPressable(
                  onTap: () => setState(() {
                    _replyToMessageId = null;
                    _replyToText = null;
                    _replyToSenderName = null;
                  }),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(LucideIcons.x,
                      size: 16, color: haven.textSecondary),
                ),
              ],
            ),
          ),

        // Input bar
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.md,
            vertical: HavenSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: haven.surface,
            border: Border(
              top: _replyToMessageId != null
                  ? BorderSide.none
                  : BorderSide(color: haven.border),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: (_, event) => handleChatInputKey(
                    event, _controller, _focusNode, _handleSend,
                  ),
                  child: HavenTextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    hintText: 'Message #${widget.channelName}',
                    autofocus: true,
                    maxLines: 5,
                    minLines: 1,
                    style: HavenTypography.body
                        .copyWith(color: haven.textPrimary),
                    borderRadius: haven.radiusLg,
                    onChanged: _onTextChanged,
                  ),
                ),
              ),
              const SizedBox(width: HavenSpacing.sm),
              HavenPressable(
                onTap: _handleSend,
                borderRadius: BorderRadius.circular(haven.radiusMd),
                backgroundColor: haven.accent,
                padding: const EdgeInsets.all(HavenSpacing.sm),
                child: Icon(
                  LucideIcons.send,
                  color: haven.textOnAccent,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Unified connection + encryption + sync status for channel headers.
/// Shows: progress bar (Connecting → Encrypting) → lock + "Encrypted" + sync status.
class _ChannelConnectionStatus extends ConsumerWidget {
  final String serverId;
  final String channelId;

  const _ChannelConnectionStatus({
    required this.serverId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectedPeers = ref.watch(peersProvider);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final localPeerId = ref.watch(identityProvider).peerId;

    return membersAsync.when(
      data: (members) {
        final otherMembers =
            members.where((m) => m.peerId != localPeerId).toList();

        final onlineMembers = otherMembers
            .where((m) => connectedPeers.containsKey(m.peerId))
            .toList();

        final encryptedMembers = onlineMembers
            .where((m) => connectedPeers[m.peerId]?.isEncrypted ?? false)
            .toList();

        // Determine connection stage.
        final ConnectionStage stage;
        if (onlineMembers.isEmpty) {
          stage = ConnectionStage.connecting;
        } else if (encryptedMembers.isEmpty) {
          stage = ConnectionStage.encrypting;
        } else {
          stage = ConnectionStage.encrypted;
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConnectionProgress(
              key: ValueKey('conn-$serverId'),
              stage: stage,
            ),
            if (stage == ConnectionStage.encrypted) ...[
              const SizedBox(width: HavenSpacing.md),
              _SyncIndicator(serverId: serverId, channelId: channelId),
            ],
          ],
        );
      },
      loading: () => ConnectionProgress(
        key: ValueKey('conn-$serverId'),
        stage: ConnectionStage.connecting,
      ),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

/// Sync status indicator (Syncing, Synced, Failed, Retrying).
/// Shown after encryption is established.
class _SyncIndicator extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;

  const _SyncIndicator({required this.serverId, required this.channelId});

  @override
  ConsumerState<_SyncIndicator> createState() => _SyncIndicatorState();
}

class _SyncIndicatorState extends ConsumerState<_SyncIndicator> {
  DateTime? _lastRetry;

  void _retry() {
    final now = DateTime.now();
    if (_lastRetry != null && now.difference(_lastRetry!).inSeconds < 3) {
      return;
    }
    _lastRetry = now;
    try {
      network_api.requestChannelSync(
        serverId: widget.serverId,
        channelId: widget.channelId,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final syncStatus = ref.watch(serverSyncStatusProvider(widget.serverId));
    final progress = ref.watch(syncProgressProvider)[widget.serverId];

    // Only show sync-related statuses (not idle/connecting).
    if (syncStatus == ServerSyncStatus.idle ||
        syncStatus == ServerSyncStatus.connecting) {
      return const SizedBox.shrink();
    }

    final Color dotColor;
    final bool useSpinning;
    final String label;
    final bool showRetry;

    switch (syncStatus) {
      case ServerSyncStatus.syncing:
        dotColor = haven.accent;
        useSpinning = true;
        label = progress != null && progress.totalCount > 0
            ? 'Syncing ${progress.receivedCount}/${progress.totalCount}...'
            : 'Syncing...';
        showRetry = false;
      case ServerSyncStatus.synced:
        dotColor = haven.success;
        useSpinning = false;
        label = 'Synced';
        showRetry = false;
      case ServerSyncStatus.retrying:
        dotColor = haven.warning;
        useSpinning = true;
        label = 'Retrying...';
        showRetry = false;
      case ServerSyncStatus.failed:
        dotColor = haven.error;
        useSpinning = false;
        label = 'Sync failed';
        showRetry = true;
      default:
        return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (useSpinning)
          _SpinningRefreshIcon(size: 10, color: dotColor)
        else
          StatusDot(color: dotColor),
        const SizedBox(width: HavenSpacing.xs),
        Text(
          label,
          style: HavenTypography.caption.copyWith(color: dotColor),
        ),
        if (showRetry) ...[
          const SizedBox(width: HavenSpacing.xs),
          HavenPressable(
            onTap: _retry,
            borderRadius: BorderRadius.circular(haven.radiusSm),
            padding: const EdgeInsets.all(2),
            child: Icon(
              LucideIcons.refreshCw,
              size: 12,
              color: haven.error,
            ),
          ),
        ],
      ],
    );
  }
}

/// A small continuously spinning refresh icon for sync indication.
class _SpinningRefreshIcon extends StatefulWidget {
  final double size;
  final Color color;

  const _SpinningRefreshIcon({required this.size, required this.color});

  @override
  State<_SpinningRefreshIcon> createState() => _SpinningRefreshIconState();
}

class _SpinningRefreshIconState extends State<_SpinningRefreshIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child:
          Icon(LucideIcons.refreshCw, size: widget.size, color: widget.color),
    );
  }
}


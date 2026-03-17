import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/file_attachment.dart';
import 'package:haven/src/core/providers/channel_chat_provider.dart';
import 'package:haven/src/core/providers/chat_provider.dart' show generateMessageId;
import 'package:haven/src/core/providers/file_transfer_provider.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/member_panel_provider.dart';
import 'package:haven/src/core/providers/unread_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/core/providers/sync_progress_provider.dart';
import 'package:haven/src/core/providers/typing_provider.dart';
import 'package:haven/src/core/providers/pinned_provider.dart';
import 'package:haven/src/core/providers/vault_status_provider.dart';
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
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:haven/src/rust/api/storage.dart' as storage_api;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

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
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  final _scrollOffsetController = ScrollOffsetController();
  final _focusNode = FocusNode();
  bool _historyLoaded = false;
  bool _isPicking = false;
  int _previousMessageCount = 0;
  String? _editingMessageId;
  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  String? _replyToImagePath;
  DateTime? _lastTypingSent;
  int? _highlightIndex;
  final _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  final _searchFocusNode = FocusNode();

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
    if (mounted) setState(() {});
    // Mark channel as read now that messages are loaded.
    final msgs = ref.read(channelChatProvider)['${widget.serverId}:${widget.channelId}'];
    final latestId = msgs != null && msgs.isNotEmpty
        ? msgs.last.messageId
        : null;
    ref.read(unreadProvider.notifier)
        .markChannelSeen(widget.serverId, widget.channelId, latestId);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    // Reset search state when leaving this pane.
    ref.read(channelSearchOpenProvider.notifier).state = false;
    super.dispose();
  }

  bool get _isNearBottom {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
    if (messages.isEmpty) return true;
    return positions.any((p) => p.index >= messages.length - 1);
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
      if (messages.isEmpty) return;
      _itemScrollController.jumpTo(index: messages.length, alignment: 1.0);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      // Pixel-level nudge — no crossfade animation.
      _scrollOffsetController.animateScroll(
        offset: 100000,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  void _scrollToMessage(int index) {
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

  void _showPinnedMessages(
    BuildContext context,
    HavenTheme haven,
    List<String> pinnedIds,
  ) {
    final messages = ref.read(channelChatProvider)[_stateKey] ?? [];
    final pinnedMessages = pinnedIds
        .map((id) => messages.where((m) => m.messageId == id).firstOrNull)
        .where((m) => m != null)
        .toList()
      ..sort((a, b) => b!.timestamp.compareTo(a!.timestamp));

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
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: pinnedMessages.length,
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

                        // Date separator between pinned messages on different days.
                        final showDate = shouldShowDateSeparator(
                          msg.timestamp,
                          index > 0 ? pinnedMessages[index - 1]!.timestamp : null,
                        );

                        final msgWidget = Padding(
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
                              if (msg.fileAttachment != null) ...[
                                if (msg.fileAttachment!.isImage &&
                                    msg.fileAttachment!.diskPath != null &&
                                    File(msg.fileAttachment!.diskPath!).existsSync())
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(haven.radiusSm),
                                    child: Image.file(
                                      File(msg.fileAttachment!.diskPath!),
                                      height: 80,
                                      fit: BoxFit.cover,
                                    ),
                                  )
                                else
                                  Text(
                                    msg.fileAttachment!.isImage ? '📷 Image' : '📎 ${msg.fileAttachment!.fileName}',
                                    style: HavenTypography.body.copyWith(
                                      color: haven.textSecondary,
                                    ),
                                  ),
                              ] else
                              Text(
                                msg.text.startsWith('[file:') ? '📎 File' : msg.text,
                                style: HavenTypography.body.copyWith(
                                  color: haven.textPrimary,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        );

                        if (showDate) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              DateSeparator(date: msg.timestamp),
                              msgWidget,
                            ],
                          );
                        }
                        if (index > 0) {
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Divider(color: haven.border, height: HavenSpacing.sm),
                              msgWidget,
                            ],
                          );
                        }
                        return msgWidget;
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
      _replyToImagePath = null;
    });
    await ref
        .read(channelChatProvider.notifier)
        .sendMessage(widget.serverId, widget.channelId, text,
            replyToMid: replyMid);
    _scrollToBottom();
  }

  Future<void> _pickAndSendFile() async {
    if (_isPicking) return;
    _isPicking = true;
    try {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) { _isPicking = false; return; }
    final file = result.files.first;
    if (file.path == null) { _isPicking = false; return; }

    // Check file size against server limit.
    try {
      final maxMbStr = await crdt_api.getServerSetting(
        serverId: widget.serverId,
        key: 'max_file_size_mb',
      );
      final maxMb = int.tryParse(maxMbStr) ?? 34;
      final maxBytes = maxMb * 1024 * 1024;
      if (file.size > maxBytes) {
        if (mounted) {
          final fileMb = (file.size / (1024 * 1024)).toStringAsFixed(1);
          HavenToast.show(
            context,
            'File too large (${fileMb}MB). Server limit is ${maxMb}MB.',
            type: HavenToastType.error,
            duration: const Duration(seconds: 4),
          );
        }
        _isPicking = false;
        return;
      }
    } catch (_) {}

    final messageId = generateMessageId();
    final fileName = file.name;
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    final isImage = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);

    // Add optimistic message with file attachment placeholder.
    ref.read(channelChatProvider.notifier).addFileMessage(
          widget.serverId,
          widget.channelId,
          messageId,
          fileName,
          file.size,
          ext,
          isImage,
          file.path!,
        );
    _jumpToBottom();

    await ref.read(fileTransferProvider.notifier).sendFile(
          serverId: widget.serverId,
          channelId: widget.channelId,
          filePath: file.path!,
          messageId: messageId,
          messageText: '',
        );
    } finally { _isPicking = false; }
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
      final isImage = attachment.isImage;
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp']
          : [attachment.fileExt];

      final baseName = attachment.fileName.contains('.')
          ? attachment.fileName.substring(0, attachment.fileName.lastIndexOf('.'))
          : attachment.fileName;

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: isImage ? '$baseName.png' : attachment.fileName,
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

      if (mounted) {
        HavenToast.show(context, 'File saved', type: HavenToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HavenToast.show(context, 'Save failed: $e', type: HavenToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final chatState = ref.watch(channelChatProvider);
    final messages = chatState[_stateKey] ?? [];

    // Auto-scroll when new messages arrive and user is near the bottom.
    // Skip on initial load (handled by _jumpToBottom in _loadHistory).
    if (_previousMessageCount > 0 &&
        messages.length > _previousMessageCount &&
        _isNearBottom) {
      _scrollToBottom();
    }
    _previousMessageCount = messages.length;

    // Focus search field when opened via global shortcut (Ctrl+K).
    ref.listen(channelSearchOpenProvider, (prev, next) {
      if (next && !(prev ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      }
      if (!next && (prev ?? false)) {
        // Closing — clear search state.
        _searchController.clear();
        setState(() => _searchResults = []);
      }
    });

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
                  onTap: () {
                    final current = ref.read(channelSearchOpenProvider);
                    ref.read(channelSearchOpenProvider.notifier).state = !current;
                    if (!current) {
                      // Opening — focus the search field after build.
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _searchFocusNode.requestFocus();
                      });
                    }
                  },
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(
                    LucideIcons.search,
                    size: 18,
                    color: ref.watch(channelSearchOpenProvider) ? haven.accent : haven.textSecondary,
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
        if (ref.watch(channelSearchOpenProvider))
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
                  focusNode: _searchFocusNode,
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
                              ref.read(channelSearchOpenProvider.notifier).state = false;
                              setState(() {
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
          child: Builder(builder: (scopeContext) =>
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) {
                MessageActionBarScope.of(scopeContext)?.dismissAll();
              }
              return false;
            },
            child: Container(
            color: haven.background,
            child: messages.isEmpty
                ? (_historyLoaded
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
                    : const SizedBox.shrink())
                : ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(scrollbars: false),
                    child: ScrollablePositionedList.builder(
                    key: ValueKey('ch-list-${widget.serverId}-${widget.channelId}'),
                    itemScrollController: _itemScrollController,
                    itemPositionsListener: _itemPositionsListener,
                    scrollOffsetController: _scrollOffsetController,
                    initialScrollIndex: messages.length,
                    initialAlignment: 1.0,
                    padding: const EdgeInsets.symmetric(
                      vertical: HavenSpacing.sm,
                    ),
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      if (index >= messages.length) {
                        return const SizedBox.shrink();
                      }
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
                        onEditStart: msg.messageId != null && msg.isMe && msg.fileAttachment == null
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
                                  _replyToText = msg.fileAttachment != null
                                      ? (msg.fileAttachment!.isImage ? '📷 Image' : '📎 ${msg.fileAttachment!.fileName}')
                                      : msg.text;
                                  _replyToSenderName = senderName;
                                  _replyToImagePath = msg.fileAttachment?.isImage == true
                                      ? msg.fileAttachment?.diskPath
                                      : null;
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
                        onDownload: msg.fileAttachment != null && msg.fileAttachment!.diskPath != null
                            ? () => _saveFile(msg.fileAttachment!)
                            : null,
                        child: Builder(builder: (_) {
                          final localPeerId =
                              ref.watch(identityProvider).peerId ?? '';
                          String? replySender;
                          String? replyText;
                          String? replyImagePath;
                          int? replyIndex;
                          if (msg.replyToMid != null) {
                            final idx = messages.indexWhere(
                                (m) => m.messageId == msg.replyToMid);
                            if (idx != -1) {
                              replyIndex = idx;
                              final original = messages[idx];
                              replyText = original.fileAttachment != null
                                  ? (original.fileAttachment!.isImage ? '📷 Image' : '📎 ${original.fileAttachment!.fileName}')
                                  : original.text;
                              replySender = serverDisplayNameFor(
                                profiles,
                                original.senderId,
                                nickname: nicknames[original.senderId] ?? '',
                              );
                              if (original.fileAttachment?.isImage == true) {
                                replyImagePath = original.fileAttachment?.diskPath;
                              }
                            }
                          }
                          return ChannelMessageBubble(
                            message: msg,
                            serverId: widget.serverId,
                            showHeader: showHeader,
                            replyToSenderName: replySender,
                            replyToText: replyText,
                            replyToImagePath: replyImagePath,
                            isHighlighted: _highlightIndex == index,
                            onReplyTap: replyIndex != null
                                ? () => _scrollToMessage(replyIndex!)
                                : null,
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
                      // Date separator between messages on different days.
                      final showDate = shouldShowDateSeparator(
                        msg.timestamp,
                        index > 0 ? messages[index - 1].timestamp : null,
                      );

                      final messageWidget = showHeader
                          ? Padding(
                              padding: const EdgeInsets.only(top: HavenSpacing.sm + 2),
                              child: wrapper,
                            )
                          : wrapper;

                      if (showDate) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DateSeparator(date: msg.timestamp),
                            messageWidget,
                          ],
                        );
                      }
                      return messageWidget;
                    },
                  ),
                  ),
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
                      Row(
                        children: [
                          if (_replyToImagePath != null && File(_replyToImagePath!).existsSync()) ...[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: Image.file(
                                File(_replyToImagePath!),
                                width: 32,
                                height: 32,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(width: HavenSpacing.xs),
                          ],
                          Expanded(
                            child: Text(
                              _replyToText ?? '',
                              style: HavenTypography.body.copyWith(
                                color: haven.textSecondary,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                HavenPressable(
                  onTap: () => setState(() {
                    _replyToMessageId = null;
                    _replyToText = null;
                    _replyToSenderName = null;
      _replyToImagePath = null;
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
              // File attachment button
              HavenPressable(
                onTap: _pickAndSendFile,
                borderRadius: BorderRadius.circular(haven.radiusMd),
                padding: const EdgeInsets.all(HavenSpacing.sm),
                child: Icon(
                  LucideIcons.paperclip,
                  color: haven.textSecondary,
                  size: 20,
                ),
              ),
              const SizedBox(width: HavenSpacing.xs),
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
                    maxLength: 4000,
                    showCounter: false,
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
              _VaultHealthIndicator(serverId: serverId),
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

/// Vault health indicator — green/yellow/red dot showing vault distribution status.
class _VaultHealthIndicator extends ConsumerWidget {
  final String serverId;
  const _VaultHealthIndicator({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);

    // Only show vault health dot when erasure coding is active (6+ members).
    // <6 members use full replication — the existing "Synced" indicator covers it.
    final memberCount = ref.watch(serverMembersProvider(serverId))
        .valueOrNull?.length ?? 0;
    if (memberCount < 6) return const SizedBox.shrink();

    final status = ref.watch(
      vaultStatusProvider.select((s) => s[serverId]),
    );
    if (status == null) return const SizedBox.shrink();

    final health = status.computeHealth();
    final color = switch (health) {
      VaultHealth.healthy => haven.success,
      VaultHealth.degraded => haven.warning,
      VaultHealth.critical => haven.error,
    };

    return HavenTooltip(
      message: status.healthMessage,
      child: Padding(
        padding: const EdgeInsets.only(left: HavenSpacing.sm),
        child: StatusDot(color: color, size: 7, pulse: health != VaultHealth.healthy),
      ),
    );
  }
}


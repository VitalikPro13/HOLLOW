import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/components/connection_progress.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Whether two consecutive messages should be grouped (same sender, within 5 min).
bool shouldGroup({
  required bool currentIsMe,
  required bool previousIsMe,
  required DateTime currentTime,
  required DateTime previousTime,
  String? currentSenderId,
  String? previousSenderId,
}) {
  // For DMs: just check isMe flag.
  // For channels: also check senderId.
  if (currentIsMe != previousIsMe) return false;
  if (currentSenderId != null &&
      previousSenderId != null &&
      currentSenderId != previousSenderId) {
    return false;
  }
  return currentTime.difference(previousTime).inMinutes.abs() < 5;
}

/// Whether a date separator should be shown between two timestamps.
bool shouldShowDateSeparator(DateTime current, DateTime? previous) {
  if (previous == null) return true; // First message always gets a date header.
  return current.year != previous.year ||
      current.month != previous.month ||
      current.day != previous.day;
}

/// ASOT-style date separator: ——— February 16, 2026 ———
class DateSeparator extends StatelessWidget {
  final DateTime date;
  const DateSeparator({super.key, required this.date});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDay = DateTime(date.year, date.month, date.day);
    final diff = today.difference(messageDay).inDays;

    final String label;
    if (diff == 0) {
      label = 'Today';
    } else if (diff == 1) {
      label = 'Yesterday';
    } else {
      const months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December',
      ];
      label = '${months[date.month - 1]} ${date.day}, ${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.only(
        top: HollowSpacing.md + 2,
        bottom: HollowSpacing.sm,
        left: HollowSpacing.lg,
        right: HollowSpacing.lg,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: hollow.border,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary.withValues(alpha: 0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: hollow.border,
            ),
          ),
        ],
      ),
    );
  }
}

class ChatPane extends ConsumerStatefulWidget {
  final String peerId;
  final int? splitPaneIndex;

  const ChatPane({
    super.key,
    required this.peerId,
    this.splitPaneIndex,
  });

  @override
  ConsumerState<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends ConsumerState<ChatPane> {
  void _handleSplitToggle(WidgetRef ref) {
    final split = ref.read(splitViewProvider);
    if (split.isSplit) {
      ref.read(splitViewProvider.notifier).closePane(
            widget.splitPaneIndex ?? 0,
          );
    } else {
      ref.read(splitViewProvider.notifier).openSplit();
    }
  }

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

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    await ref.read(chatProvider.notifier).loadHistory(widget.peerId);
    if (mounted) setState(() {});
    // Mark DM as read now that messages are loaded.
    final msgs = ref.read(chatProvider)[widget.peerId];
    final latestId = msgs != null && msgs.isNotEmpty
        ? msgs.last.messageId
        : null;
    ref.read(unreadProvider.notifier).markDmSeen(widget.peerId, latestId);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isNearBottom {
    final positions = _itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) return true;
    final messages = ref.read(chatProvider)[widget.peerId] ?? [];
    if (messages.isEmpty) return true;
    // Check if sentinel (last real message index or beyond) is visible.
    return positions.any((p) => p.index >= messages.length - 1);
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_itemScrollController.isAttached) return;
      final messages = ref.read(chatProvider)[widget.peerId] ?? [];
      if (messages.isEmpty) return;
      // Jump to sentinel item (index == messages.length) at bottom of viewport.
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
        serverId: '',
        channelId: widget.peerId,
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
        .read(chatProvider.notifier)
        .sendMessage(widget.peerId, text, replyToMid: replyMid);
    _scrollToBottom();
  }

  Future<void> _pickAndSendFile(WidgetRef ref) async {
    if (_isPicking) return;
    _isPicking = true;
    try {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) { _isPicking = false; return; }
    final file = result.files.first;
    if (file.path == null) { _isPicking = false; return; }

    final messageId = generateMessageId();
    final fileName = file.name;
    final ext = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';
    final isImage = ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);

    // Add optimistic message with file attachment placeholder.
    ref.read(chatProvider.notifier).addFileMessage(
          widget.peerId,
          messageId,
          fileName,
          file.size,
          ext,
          isImage,
          file.path!,
        );
    _jumpToBottom();

    await ref.read(fileTransferProvider.notifier).sendFile(
          peerId: widget.peerId,
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
      // Determine allowed extensions for save dialog.
      final isImage = attachment.isImage;
      final allowedExtensions = isImage
          ? ['png', 'jpg', 'jpeg', 'webp']
          : [attachment.fileExt];

      // Strip extension from filename for the dialog.
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

      // Determine target format from chosen extension.
      final targetExt = savePath.contains('.')
          ? savePath.split('.').last.toLowerCase()
          : attachment.fileExt;

      if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
        // Convert WebP to target format via Rust.
        final converted = await network_api.convertImageFormat(
          sourcePath: attachment.diskPath!,
          targetFormat: targetExt,
        );
        await File(savePath).writeAsBytes(converted);
      } else {
        // Direct copy.
        await File(attachment.diskPath!).copy(savePath);
      }

      if (mounted) {
        HollowToast.show(context, 'File saved', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e', type: HollowToastType.error);
      }
    } finally {
      _isPicking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final chatHistory = ref.watch(chatProvider);
    final messages = chatHistory[widget.peerId] ?? [];

    // Auto-scroll when new messages arrive and user is near the bottom.
    // Skip on initial load (handled by _jumpToBottom in _loadHistory).
    if (_previousMessageCount > 0 &&
        messages.length > _previousMessageCount &&
        _isNearBottom) {
      _scrollToBottom();
    }
    _previousMessageCount = messages.length;

    final typingPeers = ref.watch(typingProvider)[widget.peerId] ?? {};

    return Column(
      children: [
        // Peer ID header
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(
              bottom: BorderSide(color: hollow.border),
            ),
          ),
          child: Row(
            children: [
              HollowAvatar(peerId: widget.peerId, size: 28),
              const SizedBox(width: HollowSpacing.sm),
              Builder(builder: (_) {
                final isOnline = ref.watch(peersProvider).containsKey(widget.peerId);
                return StatusDot(
                  color: isOnline ? hollow.success : hollow.textSecondary,
                  size: 8,
                  pulse: isOnline,
                );
              }),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayNameFor(ref.watch(profileProvider), widget.peerId),
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.peerId.length > 16
                          ? '${widget.peerId.substring(0, 16)}...'
                          : widget.peerId,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              Builder(builder: (_) {
                final peer = ref.watch(peersProvider)[widget.peerId];
                final connStatus = ref.watch(connectionStatusProvider);
                final cs = connStatus.peers[widget.peerId];
                final ConnectionStage stage;
                String? detail;
                if (peer == null) {
                  stage = ConnectionStage.connecting;
                  // Only show detail for meaningful stages (not routine dial failures).
                  if (cs != null &&
                      (cs.stage == PeerConnectionStage.connected ||
                       cs.stage == PeerConnectionStage.keyExchange)) {
                    detail = cs.label;
                  }
                } else if (peer.isEncrypted) {
                  stage = ConnectionStage.encrypted;
                } else {
                  stage = ConnectionStage.encrypting;
                  if (cs != null &&
                      cs.stage == PeerConnectionStage.keyExchange) {
                    detail = cs.label;
                  }
                }
                return ConnectionProgress(
                  key: ValueKey('dm-conn-${widget.peerId}-${stage.index}'),
                  stage: stage,
                  detail: detail,
                );
              }),
              const SizedBox(width: HollowSpacing.sm),
              HollowTooltip(
                message: 'Copy peer ID',
                child: HollowPressable(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.peerId));
                    HollowToast.show(
                      context,
                      'Peer ID copied',
                      type: HollowToastType.success,
                      duration: const Duration(seconds: 1),
                    );
                  },
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.copy,
                      size: 16, color: hollow.textSecondary),
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              HollowTooltip(
                message: ref.watch(notificationSettingsProvider
                        .select((s) => s.dmEnabled[widget.peerId] ?? true))
                    ? 'Mute notifications'
                    : 'Unmute notifications',
                child: HollowPressable(
                  onTap: () {
                    final current = ref
                        .read(notificationSettingsProvider.notifier)
                        .isDmEnabled(widget.peerId);
                    ref
                        .read(notificationSettingsProvider.notifier)
                        .setDmEnabled(widget.peerId, !current);
                  },
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(
                    ref.watch(notificationSettingsProvider
                            .select((s) => s.dmEnabled[widget.peerId] ?? true))
                        ? LucideIcons.bell
                        : LucideIcons.bellOff,
                    size: 18,
                    color: ref.watch(notificationSettingsProvider
                            .select((s) => s.dmEnabled[widget.peerId] ?? true))
                        ? hollow.textSecondary
                        : hollow.textSecondary.withValues(alpha: 0.4),
                  ),
                ),
              ),
              // Split view button (dock mode only)
              if ((ref.watch(layoutModeProvider).valueOrNull ?? LayoutMode.dock) == LayoutMode.dock) ...[
                const SizedBox(width: HollowSpacing.xs),
                HollowTooltip(
                  message: ref.watch(splitViewProvider).isSplit
                      ? 'Close this pane'
                      : 'Split view',
                  child: HollowPressable(
                    onTap: () => _handleSplitToggle(ref),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(
                      LucideIcons.columns,
                      size: 16,
                      color: ref.watch(splitViewProvider).isSplit
                          ? hollow.accent
                          : hollow.textSecondary,
                    ),
                  ),
                ),
              ],
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
            color: hollow.background,
            child: messages.isEmpty
                ? (_historyLoaded
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              LucideIcons.messageCircle,
                              size: 48,
                              color: hollow.textSecondary.withValues(alpha: 0.3),
                            ),
                            const SizedBox(height: HollowSpacing.md),
                            Text(
                              'No messages yet. Say hello!',
                              style: HollowTypography.body.copyWith(
                                color: hollow.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink())
                : ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context)
                        .copyWith(scrollbars: false),
                    child: ScrollablePositionedList.builder(
                    key: ValueKey('dm-list-${widget.peerId}'),
                    itemScrollController: _itemScrollController,
                    itemPositionsListener: _itemPositionsListener,
                    scrollOffsetController: _scrollOffsetController,
                    initialScrollIndex: messages.length,
                    initialAlignment: 1.0,
                    padding: const EdgeInsets.symmetric(
                      vertical: HollowSpacing.sm,
                    ),
                    itemCount: messages.length + 1,
                    itemBuilder: (context, index) {
                      // Sentinel item at the end — lets us align
                      // "bottom of last message" to viewport bottom.
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
                          );
                      final profiles = ref.watch(profileProvider);
                      final localPeerId =
                          ref.watch(identityProvider).peerId ?? '';
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
                              .read(chatProvider.notifier)
                              .editMessage(
                                  widget.peerId, msg.messageId!, newText);
                        },
                        onEditCancel: () =>
                            setState(() => _editingMessageId = null),
                        onDelete: msg.messageId != null && msg.isMe
                            ? () => ref
                                .read(chatProvider.notifier)
                                .deleteMessage(
                                    widget.peerId, msg.messageId!)
                            : null,
                        onReply: msg.messageId != null
                            ? () {
                                final senderId =
                                    msg.isMe ? localPeerId : widget.peerId;
                                setState(() {
                                  _replyToMessageId = msg.messageId;
                                  _replyToText = msg.fileAttachment != null
                                      ? (msg.fileAttachment!.isImage ? '📷 Image' : '📎 ${msg.fileAttachment!.fileName}')
                                      : msg.text;
                                  _replyToSenderName =
                                      displayNameFor(profiles, senderId);
                                  _replyToImagePath = msg.fileAttachment?.isImage == true
                                      ? msg.fileAttachment?.diskPath
                                      : null;
                                });
                                _focusNode.requestFocus();
                              }
                            : null,
                        onReaction: msg.messageId != null
                            ? (emoji) {
                                final hasReacted =
                                    msg.reactions[emoji]?.contains(localPeerId) ?? false;
                                final notifier = ref.read(chatProvider.notifier);
                                if (hasReacted) {
                                  notifier.removeReaction(
                                      widget.peerId, msg.messageId!, emoji);
                                } else {
                                  notifier.addReaction(
                                      widget.peerId, msg.messageId!, emoji);
                                }
                              }
                            : null,
                        onDownload: msg.fileAttachment != null && msg.fileAttachment!.diskPath != null
                            ? () => _saveFile(msg.fileAttachment!)
                            : null,
                        child: Builder(builder: (_) {
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
                              final origSenderId = original.isMe
                                  ? localPeerId
                                  : widget.peerId;
                              replySender =
                                  displayNameFor(profiles, origSenderId);
                              if (original.fileAttachment?.isImage == true) {
                                replyImagePath = original.fileAttachment?.diskPath;
                              }
                            }
                          }
                          return MessageBubble(
                            message: msg,
                            peerId: widget.peerId,
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
                                    final notifier = ref.read(chatProvider.notifier);
                                    if (hasReacted) {
                                      notifier.removeReaction(
                                          widget.peerId, msg.messageId!, emoji);
                                    } else {
                                      notifier.addReaction(
                                          widget.peerId, msg.messageId!, emoji);
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
                              padding: const EdgeInsets.only(top: HollowSpacing.sm + 2),
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
                .map((pid) =>
                    displayNameFor(ref.watch(profileProvider), pid))
                .toList(),
          ),

        // Reply preview bar
        if (_replyToMessageId != null)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: hollow.surface,
              border: Border(
                top: BorderSide(color: hollow.border),
                left: BorderSide(color: hollow.accent, width: 3),
              ),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.reply, size: 14, color: hollow.accent),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Replying to ${_replyToSenderName ?? ''}',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.accent,
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
                            const SizedBox(width: HollowSpacing.xs),
                          ],
                          Expanded(
                            child: Text(
                              _replyToText ?? '',
                              style: HollowTypography.body.copyWith(
                                color: hollow.textSecondary,
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
                HollowPressable(
                  onTap: () => setState(() {
                    _replyToMessageId = null;
                    _replyToText = null;
                    _replyToSenderName = null;
      _replyToImagePath = null;
                  }),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.x,
                      size: 16, color: hollow.textSecondary),
                ),
              ],
            ),
          ),

        // Input bar
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(
              top: _replyToMessageId != null
                  ? BorderSide.none
                  : BorderSide(color: hollow.border),
            ),
          ),
          child: Row(
            children: [
              // File attachment button
              HollowPressable(
                onTap: () => _pickAndSendFile(ref),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                padding: const EdgeInsets.all(HollowSpacing.sm),
                child: Icon(
                  LucideIcons.paperclip,
                  color: hollow.textSecondary,
                  size: 20,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: Focus(
                  onKeyEvent: (_, event) => handleChatInputKey(
                    event, _controller, _focusNode, _handleSend,
                  ),
                  child: HollowTextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    hintText: 'Type a message...',
                    autofocus: true,
                    maxLines: 5,
                    minLines: 1,
                    maxLength: 4000,
                    showCounter: false,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                    ),
                    borderRadius: hollow.radiusLg,
                    onChanged: _onTextChanged,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowPressable(
                onTap: _handleSend,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                backgroundColor: hollow.accent,
                padding: const EdgeInsets.all(HollowSpacing.sm),
                child: Icon(
                  LucideIcons.send,
                  color: hollow.textOnAccent,
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

/// Typing indicator bar shown above the input area.
/// Displays up to 3 names, or "Several people are typing..." for 4+.
class TypingIndicatorBar extends StatelessWidget {
  final List<String> names;

  const TypingIndicatorBar({super.key, required this.names});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final String text;
    if (names.length == 1) {
      text = '${names[0]} is typing';
    } else if (names.length == 2) {
      text = '${names[0]} and ${names[1]} are typing';
    } else if (names.length == 3) {
      text = '${names[0]}, ${names[1]}, and ${names[2]} are typing';
    } else {
      text = 'Several people are typing';
    }

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
      alignment: Alignment.centerLeft,
      color: hollow.surface,
      child: Row(
        children: [
          Text(
            text,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontStyle: FontStyle.italic,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          TypingDots(color: hollow.textSecondary),
        ],
      ),
    );
  }
}

/// Animated bouncing dots for typing indicators.
class TypingDots extends StatefulWidget {
  final Color color;

  const TypingDots({super.key, required this.color});

  @override
  State<TypingDots> createState() => TypingDotsState();
}

class TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: null,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i * 0.2;
            final t = (_controller.value - delay).clamp(0.0, 1.0);
            final bounce = t < 0.5
                ? (t * 2) // 0→1
                : (1 - (t - 0.5) * 2); // 1→0
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.4 + bounce * 0.6),
                shape: BoxShape.circle,
              ),
            );
          }),
        );
      },
    );
  }
}

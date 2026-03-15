import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:haven/src/ui/chat/chat_input_shortcuts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/chat_provider.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/models/file_attachment.dart';
import 'package:haven/src/core/providers/file_transfer_provider.dart';
import 'package:haven/src/core/providers/notification_provider.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/core/providers/unread_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/typing_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/chat/message_action_bar.dart';
import 'package:haven/src/ui/chat/message_bubble.dart';
import 'package:haven/src/ui/components/connection_progress.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons/lucide_icons.dart';

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

class ChatPane extends ConsumerStatefulWidget {
  final String peerId;

  const ChatPane({
    super.key,
    required this.peerId,
  });

  @override
  ConsumerState<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends ConsumerState<ChatPane> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
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

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    if (_historyLoaded) return;
    _historyLoaded = true;
    await ref.read(chatProvider.notifier).loadHistory(widget.peerId);
    _jumpToBottom();
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
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  /// Instant jump — retries until maxScrollExtent stabilizes.
  int _jumpRetries = 0;
  void _jumpToBottom() {
    _jumpRetries = 0;
    _doJump();
  }

  void _doJump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final extent = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(extent);
      if (_jumpRetries < 5) {
        _jumpRetries++;
        _doJump();
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
            horizontal: HavenSpacing.lg,
            vertical: HavenSpacing.sm + 2,
          ),
          decoration: BoxDecoration(
            color: haven.surface,
            border: Border(
              bottom: BorderSide(color: haven.border),
            ),
          ),
          child: Row(
            children: [
              HavenAvatar(peerId: widget.peerId, size: 28),
              const SizedBox(width: HavenSpacing.sm),
              Builder(builder: (_) {
                final isOnline = ref.watch(peersProvider).containsKey(widget.peerId);
                return StatusDot(
                  color: isOnline ? haven.success : haven.textSecondary,
                  size: 8,
                  pulse: isOnline,
                );
              }),
              const SizedBox(width: HavenSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayNameFor(ref.watch(profileProvider), widget.peerId),
                      style: HavenTypography.body.copyWith(
                        color: haven.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.peerId.length > 16
                          ? '${widget.peerId.substring(0, 16)}...'
                          : widget.peerId,
                      style: HavenTypography.caption.copyWith(
                        color: haven.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              Builder(builder: (_) {
                final peer = ref.watch(peersProvider)[widget.peerId];
                final ConnectionStage stage;
                if (peer == null) {
                  stage = ConnectionStage.connecting;
                } else if (peer.isEncrypted) {
                  stage = ConnectionStage.encrypted;
                } else {
                  stage = ConnectionStage.encrypting;
                }
                return ConnectionProgress(
                  key: ValueKey('dm-conn-${widget.peerId}-${stage.index}'),
                  stage: stage,
                );
              }),
              const SizedBox(width: HavenSpacing.sm),
              HavenTooltip(
                message: 'Copy peer ID',
                child: HavenPressable(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: widget.peerId));
                    HavenToast.show(
                      context,
                      'Peer ID copied',
                      type: HavenToastType.success,
                      duration: const Duration(seconds: 1),
                    );
                  },
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(LucideIcons.copy,
                      size: 16, color: haven.textSecondary),
                ),
              ),
              const SizedBox(width: HavenSpacing.xs),
              HavenTooltip(
                message: ref.watch(notificationSettingsProvider
                        .select((s) => s.dmEnabled[widget.peerId] ?? true))
                    ? 'Mute notifications'
                    : 'Unmute notifications',
                child: HavenPressable(
                  onTap: () {
                    final current = ref
                        .read(notificationSettingsProvider.notifier)
                        .isDmEnabled(widget.peerId);
                    ref
                        .read(notificationSettingsProvider.notifier)
                        .setDmEnabled(widget.peerId, !current);
                  },
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(
                    ref.watch(notificationSettingsProvider
                            .select((s) => s.dmEnabled[widget.peerId] ?? true))
                        ? LucideIcons.bell
                        : LucideIcons.bellOff,
                    size: 18,
                    color: ref.watch(notificationSettingsProvider
                            .select((s) => s.dmEnabled[widget.peerId] ?? true))
                        ? haven.textSecondary
                        : haven.textSecondary.withValues(alpha: 0.4),
                  ),
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
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.messageCircle,
                          size: 48,
                          color: haven.textSecondary.withValues(alpha: 0.3),
                        ),
                        const SizedBox(height: HavenSpacing.md),
                        Text(
                          'No messages yet. Say hello!',
                          style: HavenTypography.body.copyWith(
                            color: haven.textSecondary,
                          ),
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
                          if (msg.replyToMid != null) {
                            final idx = messages.indexWhere(
                                (m) => m.messageId == msg.replyToMid);
                            if (idx != -1) {
                              final original = messages[idx];
                              replyText = original.fileAttachment != null
                                  ? (original.fileAttachment!.isImage ? '📷 Image' : '📎 ${original.fileAttachment!.fileName}')
                                  : original.text;
                              final origSenderId = original.isMe
                                  ? localPeerId
                                  : widget.peerId;
                              replySender =
                                  displayNameFor(profiles, origSenderId);
                            }
                          }
                          // Get reply image path if the original is an image.
                          String? replyImagePath;
                          if (msg.replyToMid != null) {
                            final idx = messages.indexWhere(
                                (m) => m.messageId == msg.replyToMid);
                            if (idx != -1) {
                              final orig = messages[idx];
                              if (orig.fileAttachment?.isImage == true) {
                                replyImagePath = orig.fileAttachment?.diskPath;
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
                onTap: () => _pickAndSendFile(ref),
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
                    hintText: 'Type a message...',
                    autofocus: true,
                    maxLines: 5,
                    minLines: 1,
                    style: HavenTypography.body.copyWith(
                      color: haven.textPrimary,
                    ),
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

/// Typing indicator bar shown above the input area.
/// Displays up to 3 names, or "Several people are typing..." for 4+.
class TypingIndicatorBar extends StatelessWidget {
  final List<String> names;

  const TypingIndicatorBar({super.key, required this.names});

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

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
      padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.md),
      alignment: Alignment.centerLeft,
      color: haven.surface,
      child: Row(
        children: [
          Text(
            text,
            style: HavenTypography.caption.copyWith(
              color: haven.textSecondary,
              fontStyle: FontStyle.italic,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: HavenSpacing.xs),
          TypingDots(color: haven.textSecondary),
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

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/message_bubble.dart';
import 'package:hollow/src/ui/chat/channel_message_bubble.dart';
import 'package:hollow/src/ui/chat/staged_link_preview_card.dart';
import 'package:hollow/src/ui/chat/staged_hollow_link_card.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_message_actions.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class MobileChatRoute extends ConsumerStatefulWidget {
  final String? peerId;
  final String? serverId;
  final String? channelId;
  final String? channelName;

  const MobileChatRoute({
    super.key,
    this.peerId,
    this.serverId,
    this.channelId,
    this.channelName,
  });

  bool get isDm => peerId != null;

  @override
  ConsumerState<MobileChatRoute> createState() => _MobileChatRouteState();
}

class _MobileChatRouteState extends ConsumerState<MobileChatRoute> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _scrollController = ItemScrollController();
  final _positionsListener = ItemPositionsListener.create();

  String? _replyToMessageId;
  String? _replyToText;
  String? _replyToSenderName;
  String? _editingMessageId;
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();
  DateTime? _lastTypingSent;
  bool _isInAutoScrollZone = true;
  String? _stagedFilePath;
  String? _stagedFileName;
  bool _stagedFileIsImage = false;
  static final RegExp _urlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');
  String? _stagedPreviewUrl;
  network_api.LinkPreviewRef? _stagedPreview;
  bool _stagedPreviewLoading = false;
  HollowLink? _stagedHollowLink;
  Timer? _urlDebounce;

  @override
  void initState() {
    super.initState();
    _positionsListener.itemPositions.addListener(_checkAutoScroll);
    if (widget.isDm) {
      ref.read(chatProvider.notifier).loadHistory(widget.peerId!).then((_) {
        if (mounted) _scrollToBottom();
      });
      ref.read(unreadProvider.notifier).markDmSeen(
            widget.peerId!,
            null,
          );
    } else {
      ref.read(channelChatProvider.notifier).loadHistory(
            widget.serverId!,
            widget.channelId!,
          ).then((_) {
        if (mounted) _scrollToBottom();
      });
      ref.read(unreadProvider.notifier).markChannelSeen(
            widget.serverId!,
            widget.channelId!,
            null,
          );
    }
  }

  @override
  void dispose() {
    _urlDebounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  void _checkAutoScroll() {
    final positions = _positionsListener.itemPositions.value;
    if (positions.isEmpty) return;
    final maxIndex = positions.map((p) => p.index).reduce((a, b) => a > b ? a : b);
    final count = widget.isDm
        ? (ref.read(chatProvider)[widget.peerId!]?.length ?? 0)
        : (ref.read(channelChatProvider)[widget.channelId!]?.length ?? 0);
    _isInAutoScrollZone = maxIndex >= count - 2;
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }

  void _scrollToBottom() {
    final count = widget.isDm
        ? (ref.read(chatProvider)[widget.peerId!]?.length ?? 0)
        : (ref.read(channelChatProvider)[widget.channelId!]?.length ?? 0);
    if (count > 0) {
      _scrollController.scrollTo(
        index: count,
        duration: const Duration(milliseconds: 150),
      );
    }
  }

  void _onTextChanged(String text) {
    _urlDebounce?.cancel();
    _urlDebounce = Timer(const Duration(milliseconds: 600), _detectUrl);

    if (text.isEmpty || !widget.isDm) return;
    final now = DateTime.now();
    if (_lastTypingSent != null && now.difference(_lastTypingSent!).inSeconds < 3) return;
    _lastTypingSent = now;
    try {
      network_api.sendTypingIndicator(serverId: '', channelId: widget.peerId!);
    } catch (_) {}
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    final filePath = _stagedFilePath;
    final preview = _stagedPreview;

    if (text.isEmpty && filePath == null) return;
    _controller.clear();
    _lastTypingSent = null;
    _focusNode.requestFocus();
    final replyMid = _replyToMessageId;
    _urlDebounce?.cancel();
    setState(() {
      _replyToMessageId = null;
      _replyToText = null;
      _replyToSenderName = null;
      _stagedFilePath = null;
      _stagedFileName = null;
      _stagedFileIsImage = false;
      _stagedPreviewUrl = null;
      _stagedPreview = null;
      _stagedPreviewLoading = false;
      _stagedHollowLink = null;
    });

    if (filePath != null) {
      try {
        final messageId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
        await network_api.sendFile(
          peerId: widget.isDm ? widget.peerId : null,
          serverId: widget.isDm ? null : widget.serverId,
          channelId: widget.isDm ? null : widget.channelId,
          filePath: filePath,
          messageId: messageId,
          messageText: text,
        );
      } catch (e) {
        if (mounted) {
          HollowToast.show(context, 'Failed to send file', type: HollowToastType.error);
        }
      }
    } else if (widget.isDm) {
      await ref.read(chatProvider.notifier).sendMessage(
            widget.peerId!,
            text,
            replyToMid: replyMid,
            linkPreview: preview,
          );
    } else {
      await ref.read(channelChatProvider.notifier).sendMessage(
            widget.serverId!,
            widget.channelId!,
            text,
            replyToMid: replyMid,
            linkPreview: preview,
          );
    }
    _scrollToBottom();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.path == null) return;

    const maxDmBytes = 34 * 1024 * 1024;
    if (widget.isDm && (file.size) > maxDmBytes) {
      if (mounted) {
        HollowToast.show(context, 'File too large. DM limit is 34 MB.',
            type: HollowToastType.error);
      }
      return;
    }

    try {
      final messageId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
      await network_api.sendFile(
        peerId: widget.isDm ? widget.peerId : null,
        serverId: widget.isDm ? null : widget.serverId,
        channelId: widget.isDm ? null : widget.channelId,
        filePath: file.path!,
        messageId: messageId,
        messageText: '',
      );
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to send file',
            type: HollowToastType.error);
      }
    }
  }

  void _setReply(String messageId, String senderName, String text) {
    setState(() {
      _replyToMessageId = messageId;
      _replyToSenderName = senderName;
      _replyToText = text;
    });
    _focusNode.requestFocus();
  }

  Future<void> _saveFile(FileAttachment attachment) async {
    if (attachment.diskPath == null) return;

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

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: fileName,
        bytes: bytes,
      );
      if (savePath == null) return;

      if (mounted) {
        HollowToast.show(context, 'File saved', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed: $e', type: HollowToastType.error);
      }
    }
  }

  Future<void> _requestFileFromPeer(FileAttachment attachment, String senderId) async {
    if (senderId.isEmpty) {
      if (mounted) {
        HollowToast.show(context, 'Cannot download: unknown sender', type: HollowToastType.error);
      }
      return;
    }
    try {
      if (mounted) {
        HollowToast.show(context, 'Requesting file from peer...', type: HollowToastType.info);
      }
      await network_api.requestFileFromPeer(
        fileId: attachment.fileId,
        peerId: senderId,
        chunks: [],
      );
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'File request failed: $e', type: HollowToastType.error);
      }
    }
  }

  void _detectUrl() {
    if (!mounted) return;
    final text = _controller.text;
    final match = _urlRegex.firstMatch(text);
    final url = match?.group(0);
    if (url == _stagedPreviewUrl) return;
    if (url == null) {
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
        _stagedHollowLink = null;
      });
      return;
    }

    final hollowLinks = extractHollowLinks(url);
    if (hollowLinks.isNotEmpty) {
      setState(() {
        _stagedPreviewUrl = url;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
        _stagedHollowLink = hollowLinks.first;
      });
      return;
    }

    setState(() {
      _stagedPreviewUrl = url;
      _stagedPreview = null;
      _stagedPreviewLoading = true;
      _stagedHollowLink = null;
    });
    _fetchPreview(url);
  }

  Future<void> _fetchPreview(String url) async {
    try {
      final preview = await network_api.fetchLinkPreview(url: url);
      if (!mounted || _stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreview = preview;
        _stagedPreviewLoading = false;
      });
    } catch (_) {
      if (!mounted || _stagedPreviewUrl != url) return;
      setState(() {
        _stagedPreviewUrl = null;
        _stagedPreview = null;
        _stagedPreviewLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            _MobileChatHeader(
              peerId: widget.peerId,
              channelName: widget.channelName,
            ),
            Expanded(
              child: widget.isDm ? _buildDmMessages() : _buildChannelMessages(),
            ),
            _TypingBar(
              contextKey: widget.isDm
                  ? widget.peerId!
                  : '${widget.serverId}:${widget.channelId}',
            ),
            if (_replyToMessageId != null)
              _ReplyPreview(
                senderName: _replyToSenderName ?? '',
                text: _replyToText ?? '',
                onCancel: () => setState(() {
                  _replyToMessageId = null;
                  _replyToText = null;
                  _replyToSenderName = null;
                }),
              ),
            if (_stagedHollowLink != null)
              StagedHollowLinkCard(
                link: _stagedHollowLink!,
                onDismiss: () {
                  _urlDebounce?.cancel();
                  setState(() {
                    _stagedPreviewUrl = null;
                    _stagedHollowLink = null;
                  });
                },
              )
            else if (_stagedPreviewUrl != null && _stagedHollowLink == null)
              StagedLinkPreviewCard(
                url: _stagedPreviewUrl!,
                preview: _stagedPreview,
                loading: _stagedPreviewLoading,
                onDismiss: () {
                  _urlDebounce?.cancel();
                  setState(() {
                    _stagedPreviewUrl = null;
                    _stagedPreview = null;
                    _stagedPreviewLoading = false;
                  });
                },
              ),
            if (_stagedFilePath != null)
              _StagedFilePreview(
                fileName: _stagedFileName ?? '',
                filePath: _stagedFilePath!,
                isImage: _stagedFileIsImage,
                onCancel: () => setState(() {
                  _stagedFilePath = null;
                  _stagedFileName = null;
                  _stagedFileIsImage = false;
                }),
              ),
            _MobileInputBar(
              controller: _controller,
              focusNode: _focusNode,
              onSend: _handleSend,
              onPickFile: _pickFile,
              onChanged: _onTextChanged,
              hasStagedFile: _stagedFilePath != null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDmMessages() {
    final chatHistory = ref.watch(chatProvider);
    final messages = chatHistory[widget.peerId!] ?? [];
    final profiles = ref.watch(profileProvider);

    ref.listen<Map<String, List<ChatMessage>>>(chatProvider, (prev, next) {
      final prevLen = (prev?[widget.peerId!] ?? const []).length;
      final nextLen = (next[widget.peerId!] ?? const []).length;
      if (nextLen > prevLen && _isInAutoScrollZone) _scrollToBottom();
    });

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages yet', style: HollowTypography.body.copyWith(
          color: HollowTheme.of(context).textSecondary,
        )),
      );
    }

    return ScrollablePositionedList.builder(
      itemScrollController: _scrollController,
      itemPositionsListener: _positionsListener,
      itemCount: messages.length + 1,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.sm,
      ),
      itemBuilder: (context, index) {
        if (index == messages.length) return const SizedBox(height: 8);
        final msg = messages[index];
        final prev = index > 0 ? messages[index - 1] : null;

        final showDate = prev == null || !_sameDay(prev.timestamp, msg.timestamp);
        final showHeader = prev == null ||
            prev.isMe != msg.isMe ||
            msg.timestamp.difference(prev.timestamp).inMinutes > 5;

        final localPeerId = ref.read(identityProvider).peerId ?? '';
        final senderName = msg.isMe
            ? 'You'
            : displayNameFor(profiles, widget.peerId!);

        // Edit mode: show inline editor instead of bubble.
        if (_editingMessageId != null && _editingMessageId == msg.messageId) {
          final editWidget = _buildEditView(
            originalText: msg.text,
            onSave: (newText) {
              ref.read(chatProvider.notifier).editMessage(
                    widget.peerId!, msg.messageId!, newText);
              setState(() => _editingMessageId = null);
            },
            onCancel: () => setState(() => _editingMessageId = null),
          );
          return showDate
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  _DateSeparator(date: msg.timestamp), editWidget])
              : editWidget;
        }

        // Look up reply target for this message.
        String? replySender;
        String? replyText;
        if (msg.replyToMid != null) {
          final idx = messages.indexWhere((m) => m.messageId == msg.replyToMid);
          if (idx != -1) {
            final original = messages[idx];
            replyText = original.fileAttachment != null
                ? (original.fileAttachment!.isImage
                    ? '📷 Image'
                    : '📎 ${original.fileAttachment!.fileName}')
                : original.text;
            final origSenderId = original.isMe ? localPeerId : widget.peerId!;
            replySender = displayNameFor(profiles, origSenderId);
          }
        }

        final bubble = _LongPressMessage(
          onLongPress: () => _showDmActions(msg, senderName, localPeerId),
          child: MessageBubble(
            message: msg,
            peerId: widget.peerId!,
            showHeader: showHeader,
            replyToSenderName: replySender,
            replyToText: replyText,
            onToggleReaction: msg.messageId != null
                ? (emoji) {
                    final hasReacted =
                        msg.reactions[emoji]?.contains(localPeerId) ?? false;
                    final notifier = ref.read(chatProvider.notifier);
                    if (hasReacted) {
                      notifier.removeReaction(
                          widget.peerId!, msg.messageId!, emoji);
                    } else {
                      notifier.addReaction(
                          widget.peerId!, msg.messageId!, emoji);
                    }
                  }
                : null,
          ),
        );

        final messageWidget = showHeader
            ? Padding(
                padding: const EdgeInsets.only(top: HollowSpacing.sm + 2),
                child: bubble,
              )
            : bubble;

        if (showDate) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DateSeparator(date: msg.timestamp),
              messageWidget,
            ],
          );
        }
        return messageWidget;
      },
    );
  }

  Widget _buildChannelMessages() {
    final channelHistory = ref.watch(channelChatProvider);
    final messages = channelHistory[widget.channelId!] ?? [];
    final profiles = ref.watch(profileProvider);

    ref.listen(channelChatProvider, (prev, next) {
      final prevLen = (prev?[widget.channelId!] ?? const []).length;
      final nextLen = (next[widget.channelId!] ?? const []).length;
      if (nextLen > prevLen && _isInAutoScrollZone) _scrollToBottom();
    });

    if (messages.isEmpty) {
      return Center(
        child: Text('No messages yet', style: HollowTypography.body.copyWith(
          color: HollowTheme.of(context).textSecondary,
        )),
      );
    }

    return ScrollablePositionedList.builder(
      itemScrollController: _scrollController,
      itemPositionsListener: _positionsListener,
      itemCount: messages.length + 1,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.sm,
      ),
      itemBuilder: (context, index) {
        if (index == messages.length) return const SizedBox(height: 8);
        final msg = messages[index];
        final prev = index > 0 ? messages[index - 1] : null;

        final showDate = prev == null || !_sameDay(prev.timestamp, msg.timestamp);
        final showHeader = prev == null ||
            prev.senderId != msg.senderId ||
            msg.timestamp.difference(prev.timestamp).inMinutes > 5;

        final localPeerId = ref.read(identityProvider).peerId ?? '';
        final senderName = displayNameFor(profiles, msg.senderId);

        // Edit mode: show inline editor instead of bubble.
        if (_editingMessageId != null && _editingMessageId == msg.messageId) {
          final editWidget = _buildEditView(
            originalText: msg.text,
            onSave: (newText) {
              ref.read(channelChatProvider.notifier).editMessage(
                    widget.serverId!, widget.channelId!, msg.messageId!, newText);
              setState(() => _editingMessageId = null);
            },
            onCancel: () => setState(() => _editingMessageId = null),
          );
          return showDate
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  _DateSeparator(date: msg.timestamp), editWidget])
              : editWidget;
        }

        // Look up reply target for this message.
        String? replySender;
        String? replyText;
        if (msg.replyToMid != null) {
          final idx = messages.indexWhere((m) => m.messageId == msg.replyToMid);
          if (idx != -1) {
            final original = messages[idx];
            replyText = original.fileAttachment != null
                ? (original.fileAttachment!.isImage
                    ? '📷 Image'
                    : '📎 ${original.fileAttachment!.fileName}')
                : original.text;
            replySender = displayNameFor(profiles, original.senderId);
          }
        }

        final bubble = _LongPressMessage(
          onLongPress: () => _showChannelActions(msg, senderName, localPeerId),
          child: ChannelMessageBubble(
            message: msg,
            serverId: widget.serverId!,
            showHeader: showHeader,
            replyToSenderName: replySender,
            replyToText: replyText,
            onToggleReaction: msg.messageId != null
                ? (emoji) {
                    final hasReacted =
                        msg.reactions[emoji]?.contains(localPeerId) ?? false;
                    final notifier = ref.read(channelChatProvider.notifier);
                    if (hasReacted) {
                      notifier.removeReaction(widget.serverId!,
                          widget.channelId!, msg.messageId!, emoji);
                    } else {
                      notifier.addReaction(widget.serverId!,
                          widget.channelId!, msg.messageId!, emoji);
                    }
                  }
                : null,
          ),
        );

        final messageWidget = showHeader
            ? Padding(
                padding: const EdgeInsets.only(top: HollowSpacing.sm + 2),
                child: bubble,
              )
            : bubble;

        if (showDate) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DateSeparator(date: msg.timestamp),
              messageWidget,
            ],
          );
        }
        return messageWidget;
      },
    );
  }

  // ─────────────────────────────────────────────────
  // Action sheet triggers
  // ─────────────────────────────────────────────────

  void _showDmActions(ChatMessage msg, String senderName, String localPeerId) {
    showMobileMessageActions(
      context: context,
      messageText: msg.text,
      senderName: senderName,
      timestamp: _formatTime(msg.timestamp),
      isMe: msg.isMe,
      onReply: msg.messageId != null
          ? () => _setReply(msg.messageId!, senderName, msg.text)
          : null,
      onEdit: msg.messageId != null && msg.isMe && msg.fileAttachment == null
          ? () => setState(() => _editingMessageId = msg.messageId)
          : null,
      onDelete: msg.messageId != null && msg.isMe
          ? () => ref.read(chatProvider.notifier)
              .deleteMessage(widget.peerId!, msg.messageId!)
          : null,
      onCopy: msg.text.isNotEmpty && !msg.text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: msg.text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: msg.fileAttachment != null
          ? () {
              final att = msg.fileAttachment!;
              final transfer = ref.read(fileTransferProvider)[att.fileId];
              if (transfer != null && transfer.isDownloading) {
                HollowToast.show(context, 'File is already downloading...', type: HollowToastType.info);
                return;
              }
              if (att.diskPath != null) {
                _saveFile(att);
              } else {
                _requestFileFromPeer(att, widget.peerId!);
              }
            }
          : null,
      onReaction: msg.messageId != null
          ? (emoji) {
              final hasReacted =
                  msg.reactions[emoji]?.contains(localPeerId) ?? false;
              final notifier = ref.read(chatProvider.notifier);
              if (hasReacted) {
                notifier.removeReaction(
                    widget.peerId!, msg.messageId!, emoji);
              } else {
                notifier.addReaction(widget.peerId!, msg.messageId!, emoji);
              }
            }
          : null,
      onInfo: msg.messageId != null
          ? () {
              final senderId = msg.isMe ? localPeerId : widget.peerId!;
              showMessageProofDialog(
                context,
                MessageProofData(
                  senderPeerId: senderId,
                  senderDisplayName: senderName,
                  text: msg.text,
                  timestampMs: (msg.editedAt ?? msg.timestamp)
                      .millisecondsSinceEpoch,
                  signature: msg.signature,
                  publicKey: msg.publicKey,
                  messageId: msg.messageId,
                  context: msg.isMe ? widget.peerId! : localPeerId,
                  msgType: 'dm',
                  fileAttachment: msg.fileAttachment,
                ),
              );
            }
          : null,
    );
  }

  void _showChannelActions(ChannelChatMessage msg, String senderName, String localPeerId) {
    showMobileMessageActions(
      context: context,
      messageText: msg.text,
      senderName: senderName,
      timestamp: _formatTime(msg.timestamp),
      isMe: msg.isMe,
      onReply: msg.messageId != null
          ? () => _setReply(msg.messageId!, senderName, msg.text)
          : null,
      onEdit: msg.messageId != null && msg.isMe && msg.fileAttachment == null
          ? () => setState(() => _editingMessageId = msg.messageId)
          : null,
      onDelete: msg.messageId != null && msg.isMe
          ? () => ref.read(channelChatProvider.notifier)
              .deleteMessage(widget.serverId!, widget.channelId!, msg.messageId!)
          : null,
      onCopy: msg.text.isNotEmpty && !msg.text.startsWith('[file:')
          ? () {
              Clipboard.setData(ClipboardData(text: msg.text));
              HollowToast.show(context, 'Copied to clipboard',
                  type: HollowToastType.success);
            }
          : null,
      onDownload: msg.fileAttachment != null
          ? () {
              final att = msg.fileAttachment!;
              final transfer = ref.read(fileTransferProvider)[att.fileId];
              if (transfer != null && transfer.isDownloading) {
                HollowToast.show(context, 'File is already downloading...', type: HollowToastType.info);
                return;
              }
              if (att.diskPath != null) {
                _saveFile(att);
              } else {
                _requestFileFromPeer(att, msg.senderId);
              }
            }
          : null,
      onReaction: msg.messageId != null
          ? (emoji) {
              final hasReacted =
                  msg.reactions[emoji]?.contains(localPeerId) ?? false;
              final notifier = ref.read(channelChatProvider.notifier);
              if (hasReacted) {
                notifier.removeReaction(widget.serverId!,
                    widget.channelId!, msg.messageId!, emoji);
              } else {
                notifier.addReaction(widget.serverId!,
                    widget.channelId!, msg.messageId!, emoji);
              }
            }
          : null,
      onInfo: msg.messageId != null
          ? () {
              showMessageProofDialog(
                context,
                MessageProofData(
                  senderPeerId: msg.senderId,
                  senderDisplayName: senderName,
                  text: msg.text,
                  timestampMs: (msg.editedAt ?? msg.timestamp)
                      .millisecondsSinceEpoch,
                  signature: msg.signature,
                  publicKey: msg.publicKey,
                  messageId: msg.messageId,
                  context: '${widget.serverId!}:${widget.channelId!}',
                  msgType: 'ch',
                  fileAttachment: msg.fileAttachment,
                ),
              );
            }
          : null,
    );
  }

  // ─────────────────────────────────────────────────
  // Inline edit view
  // ─────────────────────────────────────────────────

  Widget _buildEditView({
    required String originalText,
    required void Function(String) onSave,
    required VoidCallback onCancel,
  }) {
    final hollow = HollowTheme.of(context);

    _editController.text = originalText;
    _editController.selection = TextSelection.fromPosition(
      TextPosition(offset: originalText.length),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editFocusNode.requestFocus();
    });

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: hollow.accent),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              color: hollow.elevated,
            ),
            child: TextField(
              controller: _editController,
              focusNode: _editFocusNode,
              maxLines: 5,
              minLines: 1,
              textInputAction: TextInputAction.newline,
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.all(HollowSpacing.sm),
                border: InputBorder.none,
                hintText: 'Edit your message...',
                hintStyle: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HollowPressable(
                onTap: onCancel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Text('Cancel',
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textSecondary)),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowPressable(
                onTap: () {
                  final newText = _editController.text.trim();
                  if (newText.isNotEmpty && newText != originalText) {
                    onSave(newText);
                  } else {
                    onCancel();
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.accent,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                  ),
                  child: Text('Save',
                      style: HollowTypography.caption.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      )),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ─────────────────────────────────────────────────
// Chat header with back button + name (tappable for profile sheet)
// ─────────────────────────────────────────────────

class _MobileChatHeader extends ConsumerWidget {
  final String? peerId;
  final String? channelName;

  const _MobileChatHeader({this.peerId, this.channelName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final isDm = peerId != null;

    String title;
    if (isDm) {
      title = displayNameFor(profiles, peerId!);
    } else {
      title = '# ${channelName ?? 'Channel'}';
    }

    final isOnline = isDm &&
        ref.watch(peersProvider.select((p) => p.containsKey(peerId)));

    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
      child: Row(
        children: [
          HollowPressable(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(LucideIcons.arrowLeft, size: 22, color: hollow.textPrimary),
          ),
          const SizedBox(width: HollowSpacing.xs),
          if (isDm) ...[
            SizedBox(
              width: 32, height: 32,
              child: Stack(
                children: [
                  HollowAvatar(peerId: peerId!, size: 32),
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: hollow.surface, shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(1),
                      child: StatusDot(
                        color: isOnline ? hollow.success : hollow.textSecondary,
                        size: 8, pulse: isOnline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
          ],
          Expanded(
            child: HollowPressable(
              onTap: isDm ? () => _showProfileSheet(context, ref, peerId!) : null,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: HollowTypography.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: hollow.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isDm)
                    Text(
                      isOnline ? 'Online' : 'Offline',
                      style: HollowTypography.caption.copyWith(
                        color: isOnline ? hollow.success : hollow.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showProfileSheet(BuildContext context, WidgetRef ref, String peerId) {
    final hollow = HollowTheme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => _ProfileSheet(peerId: peerId),
    );
  }
}

// ─────────────────────────────────────────────────
// Input bar (attach + text field + send)
// ─────────────────────────────────────────────────

class _MobileInputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final VoidCallback onPickFile;
  final ValueChanged<String> onChanged;
  final bool hasStagedFile;

  const _MobileInputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.onPickFile,
    required this.onChanged,
    this.hasStagedFile = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          HollowPressable(
            onTap: onPickFile,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(LucideIcons.paperclip, color: hollow.textSecondary, size: 22),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                maxLines: 5,
                minLines: 1,
                textInputAction: TextInputAction.newline,
                style: HollowTypography.body.copyWith(color: hollow.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Type a message...',
                  hintStyle: HollowTypography.body.copyWith(color: hollow.textSecondary),
                  filled: true,
                  fillColor: hollow.background,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.md,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(hollow.radiusXl),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: onChanged,
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            onTap: onSend,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            backgroundColor: hasStagedFile ? hollow.accent : hollow.accent,
            padding: const EdgeInsets.all(HollowSpacing.sm + 2),
            child: Icon(LucideIcons.send, color: hollow.textOnAccent, size: 20),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Reply preview bar
// ─────────────────────────────────────────────────

class _ReplyPreview extends StatelessWidget {
  final String senderName;
  final String text;
  final VoidCallback onCancel;

  const _ReplyPreview({
    required this.senderName,
    required this.text,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 2, height: 28,
            decoration: BoxDecoration(
              color: hollow.accent,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(senderName, style: HollowTypography.caption.copyWith(
                  color: hollow.accent, fontWeight: FontWeight.w600,
                )),
                Text(text, style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                ), maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          HollowPressable(
            onTap: onCancel,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Staged file preview (above input bar)
// ─────────────────────────────────────────────────

class _StagedFilePreview extends StatelessWidget {
  final String fileName;
  final String filePath;
  final bool isImage;
  final VoidCallback onCancel;

  const _StagedFilePreview({
    required this.fileName,
    required this.filePath,
    required this.isImage,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              child: Image.file(
                File(filePath),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => Container(
                  width: 48,
                  height: 48,
                  color: hollow.elevated,
                  child: Icon(LucideIcons.image, size: 20, color: hollow.textSecondary),
                ),
              ),
            )
          else
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              child: Icon(LucideIcons.file, size: 20, color: hollow.textSecondary),
            ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              fileName,
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          HollowPressable(
            onTap: onCancel,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x, size: 18, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Long-press wrapper with teal highlight + full-width hit target
// ─────────────────────────────────────────────────

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
          color: _pressing ? hollow.accent.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: widget.child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Date separator
// ─────────────────────────────────────────────────

class _DateSeparator extends StatelessWidget {
  final DateTime date;
  const _DateSeparator({required this.date});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final now = DateTime.now();
    String label;
    if (_sameDay(date, now)) {
      label = 'Today';
    } else if (_sameDay(date, now.subtract(const Duration(days: 1)))) {
      label = 'Yesterday';
    } else {
      label = '${date.day}/${date.month}/${date.year}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.md),
      child: Row(
        children: [
          Expanded(child: Divider(color: hollow.border, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Text(label, style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            )),
          ),
          Expanded(child: Divider(color: hollow.border, height: 1)),
        ],
      ),
    );
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ─────────────────────────────────────────────────
// Typing indicator bar
// ─────────────────────────────────────────────────

class _TypingBar extends ConsumerWidget {
  final String contextKey;

  const _TypingBar({required this.contextKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final typingPeers = ref.watch(typingProvider)[contextKey] ?? {};
    if (typingPeers.isEmpty) return const SizedBox.shrink();

    final profiles = ref.watch(profileProvider);
    final names = typingPeers
        .map((pid) => displayNameFor(profiles, pid))
        .toList();

    String text;
    if (names.length == 1) {
      text = '${names.first} is typing...';
    } else if (names.length == 2) {
      text = '${names[0]} and ${names[1]} are typing...';
    } else {
      text = '${names.length} people are typing...';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.xs,
      ),
      child: Text(
        text,
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Profile bottom sheet with banner
// ─────────────────────────────────────────────────

Color _bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360;
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

class _ProfileSheet extends ConsumerWidget {
  final String peerId;

  const _ProfileSheet({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final profile = profiles[peerId];
    final name = displayNameFor(profiles, peerId);
    final isOnline = ref.watch(peersProvider.select((p) => p.containsKey(peerId)));
    final bannerBytes = ref.watch(bannerProvider(peerId)).valueOrNull;
    final bannerColor = _bannerColorFromId(peerId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle
        Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.sm),
          child: Container(
            width: 32, height: 4,
            decoration: BoxDecoration(
              color: hollow.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Banner
        const SizedBox(height: HollowSpacing.sm),
        SizedBox(
          height: 180,
          width: double.infinity,
          child: bannerBytes != null && bannerBytes.isNotEmpty
              ? AnimatedGifImage(
                  bytes: bannerBytes,
                  height: 180,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorWidget: Container(
                    height: 180,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                      ),
                    ),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                    ),
                  ),
                ),
        ),

        // Avatar overlapping banner
        Transform.translate(
          offset: const Offset(0, -36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border: Border.all(color: hollow.surface, width: 3),
                ),
                child: HollowAvatar(peerId: peerId, size: 72),
              ),
              const SizedBox(height: HollowSpacing.sm),
              Text(name, style: HollowTypography.heading.copyWith(
                color: hollow.textPrimary,
              )),
              const SizedBox(height: HollowSpacing.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  StatusDot(
                    color: isOnline ? hollow.success : hollow.textSecondary,
                    size: 8, pulse: isOnline,
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  Text(
                    isOnline ? 'Online' : 'Offline',
                    style: HollowTypography.body.copyWith(
                      color: isOnline ? hollow.success : hollow.textSecondary,
                    ),
                  ),
                ],
              ),
              if (profile?.status != null && profile!.status.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.sm),
                Text(
                  profile.status,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.accent,
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
              if (profile?.aboutMe != null && profile!.aboutMe.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Text(
                    profile.aboutMe,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              const SizedBox(height: HollowSpacing.md),
            ],
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/chat/album_bubble.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/ui/chat/message_row.dart';

/// A DM message as a [MessageRow].
class MessageBubble extends ConsumerWidget {
  final ChatMessage message;
  final String peerId;
  final bool showHeader;
  final String? replyToSenderId;
  final String? replyToSenderName;
  final String? replyToText;
  final String? replyToImagePath;
  final bool isHighlighted;
  final VoidCallback? onReplyTap;
  final void Function(String emoji)? onToggleReaction;
  final bool tileWithPrev;
  final bool tileWithNext;
  final List<AlbumItem>? album;

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerId,
    required this.showHeader,
    this.replyToSenderId,
    this.replyToSenderName,
    this.replyToText,
    this.replyToImagePath,
    this.isHighlighted = false,
    this.onReplyTap,
    this.onToggleReaction,
    this.tileWithPrev = false,
    this.tileWithNext = false,
    this.album,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sender = message.isMe
        ? ref.watch(identityProvider).peerId ?? ''
        : peerId;
    return MessageRow(
      messageId: message.messageId,
      senderId: sender,
      isMe: message.isMe,
      text: message.text,
      timestamp: message.timestamp,
      editedAt: message.editedAt,
      replyToMid: message.replyToMid,
      reactions: message.reactions,
      fileAttachment: message.fileAttachment,
      linkPreview: message.linkPreview,
      showHeader: showHeader,
      replyToSenderId: replyToSenderId,
      replyToSenderName: replyToSenderName,
      replyToText: replyToText,
      replyToImagePath: replyToImagePath,
      isHighlighted: isHighlighted,
      onReplyTap: onReplyTap,
      onToggleReaction: onToggleReaction,
      tileWithPrev: tileWithPrev,
      tileWithNext: tileWithNext,
      album: album,
    );
  }
}

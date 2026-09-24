import 'package:flutter/material.dart';
import 'package:hollow/src/ui/chat/album_bubble.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/ui/chat/message_row.dart';

/// A channel message as a [MessageRow].
class ChannelMessageBubble extends StatelessWidget {
  final ChannelChatMessage message;
  final String serverId;
  final bool showHeader;
  final String? replyToSenderId;
  final String? replyToSenderName;
  final String? replyToText;
  final String? replyToImagePath;
  final bool isHighlighted;
  final bool isMentioned;
  final VoidCallback? onReplyTap;
  final void Function(String emoji)? onToggleReaction;
  final bool tileWithPrev;
  final bool tileWithNext;
  final List<AlbumItem>? album;

  const ChannelMessageBubble({
    super.key,
    required this.message,
    required this.serverId,
    required this.showHeader,
    this.replyToSenderId,
    this.replyToSenderName,
    this.replyToText,
    this.replyToImagePath,
    this.isHighlighted = false,
    this.isMentioned = false,
    this.onReplyTap,
    this.onToggleReaction,
    this.tileWithPrev = false,
    this.tileWithNext = false,
    this.album,
  });

  @override
  Widget build(BuildContext context) => MessageRow(
        messageId: message.messageId,
        senderId: message.senderId,
        isMe: message.isMe,
        text: message.text,
        timestamp: message.timestamp,
        editedAt: message.editedAt,
        replyToMid: message.replyToMid,
        reactions: message.reactions,
        fileAttachment: message.fileAttachment,
        linkPreview: message.linkPreview,
        serverId: serverId,
        showHeader: showHeader,
        replyToSenderId: replyToSenderId,
        replyToSenderName: replyToSenderName,
        replyToText: replyToText,
        replyToImagePath: replyToImagePath,
        isHighlighted: isHighlighted,
        isMentioned: isMentioned,
        onReplyTap: onReplyTap,
        onToggleReaction: onToggleReaction,
        tileWithPrev: tileWithPrev,
        tileWithNext: tileWithNext,
        album: album,
      );
}

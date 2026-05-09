import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/file_attachment_widget.dart';
import 'package:hollow/src/ui/chat/hollow_link_card.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/link_preview_card.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/chat/reaction_bar.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';

/// Flat message row for channel messages — no bubbles.
///
/// [showHeader] controls whether avatar + name + timestamp are shown
/// (first message in a group) or just indented text (continuation).
class ChannelMessageBubble extends ConsumerWidget {
  final ChannelChatMessage message;
  final String serverId;
  final bool showHeader;
  final String? replyToSenderName;
  final String? replyToText;
  final String? replyToImagePath;
  final bool isHighlighted;
  final bool isMentioned;
  final VoidCallback? onReplyTap;
  final void Function(String emoji)? onToggleReaction;

  const ChannelMessageBubble({
    super.key,
    required this.message,
    required this.serverId,
    required this.showHeader,
    this.replyToSenderName,
    this.replyToText,
    this.replyToImagePath,
    this.isHighlighted = false,
    this.isMentioned = false,
    this.onReplyTap,
    this.onToggleReaction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final senderProfile = ref.watch(
        profileProvider.select((p) => p[message.senderId]));
    final senderNickname = ref.watch(
        serverNicknamesProvider(serverId).select((n) => n[message.senderId]));
    final senderName = serverDisplayNameForPeer(
      senderProfile,
      message.senderId,
      nickname: senderNickname ?? '',
    );
    final isMe = message.isMe;
    final time =
        '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}';
    final isEdited = message.editedAt != null;

    const avatarSize = 32.0;
    const avatarGap = HollowSpacing.sm + 2; // 10px
    const indent = avatarSize + avatarGap;

    final hasReply = message.replyToMid != null && replyToText != null;

    Widget? replyWidget;
    if (hasReply) {
      final replyContent = Row(
        children: [
          Container(
            width: 2,
            height: 28,
            decoration: BoxDecoration(
              color: hollow.textSecondary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  replyToSenderName ?? '',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent,
                    fontWeight: FontWeight.w600,
                    fontSize: 10,
                  ),
                ),
                Text(
                  replyToText!,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (replyToImagePath != null && File(replyToImagePath!).existsSync())
            Padding(
              padding: const EdgeInsets.only(left: HollowSpacing.sm),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: replyToImagePath!.toLowerCase().endsWith('.gif')
                    ? GifFileImage(
                        diskPath: replyToImagePath!,
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                      )
                    : Image.file(
                        File(replyToImagePath!),
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                      ),
              ),
            ),
        ],
      );
      replyWidget = Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: onReplyTap != null
            ? MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onReplyTap,
                  child: replyContent,
                ),
              )
            : replyContent,
      );
    }

    final localPeerId = ref.watch(identityProvider).peerId ?? '';

    // Memoized across all message bubbles — recomputes only when members change.
    final memberNames = ref.watch(serverMemberNamesProvider(serverId));

    final isFileOnly = message.fileAttachment != null &&
        (message.text.isEmpty || message.text.startsWith('[file:'));
    final messageTextWidget = isFileOnly
        ? null
        : buildMessageText(
            message.text,
            context,
            memberNames: memberNames,
            suffixSpans: isEdited
                ? [
                    TextSpan(
                      text: ' (edited)',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary.withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    ),
                  ]
                : null,
          );

    final linkPreviewWidget = message.linkPreview != null
        ? Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xs),
            child: LinkPreviewCard(preview: message.linkPreview!),
          )
        : null;

    final textForLinks = message.text.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    final hollowLinks = extractHollowLinks(textForLinks);
    final hollowLinkWidgets = hollowLinks.isNotEmpty
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final link in hollowLinks.take(3))
                Padding(
                  padding: const EdgeInsets.only(top: HollowSpacing.xs),
                  child: HollowLinkCard(link: link),
                ),
            ],
          )
        : null;

    final fileWidget = message.fileAttachment != null
        ? Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xs),
            child: FileAttachmentWidget(
              attachment: message.fileAttachment!,
            ),
          )
        : null;

    final reactionBarWidget = message.reactions.isNotEmpty
        ? ReactionBar(
            reactions: message.reactions,
            localPeerId: localPeerId,
            onToggleReaction: onToggleReaction,
          )
        : null;

    final meDecoration = BoxDecoration(
      border: Border(
        right: BorderSide(color: hollow.accent, width: 2),
      ),
    );

    final highlightDecoration = isHighlighted || isMentioned
        ? BoxDecoration(
            color: hollow.accent.withValues(alpha: 0.08),
            border: isMe ? meDecoration.border : null,
          )
        : (isMe ? meDecoration : null);

    if (showHeader) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        padding: const EdgeInsets.only(
          top: 4,
          bottom: 4,
          left: HollowSpacing.md,
          right: HollowSpacing.md,
        ),
        decoration: highlightDecoration,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: HollowAvatar(peerId: message.senderId, size: avatarSize),
            ),
            const SizedBox(width: avatarGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        senderName,
                        style: HollowTypography.body.copyWith(
                          color: isMe
                              ? hollow.accent
                              : nameColorFromId(message.senderId),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        time,
                        style: HollowTypography.caption.copyWith(
                          color:
                              hollow.textSecondary.withValues(alpha: 0.5),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  ?replyWidget,
                  ?messageTextWidget,
                  ?linkPreviewWidget,
                  ?hollowLinkWidgets,
                  ?fileWidget,
                  ?reactionBarWidget,
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Continuation message — indented, no avatar/name.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      padding: const EdgeInsets.only(
        top: 2,
        bottom: 2,
        left: HollowSpacing.md + indent,
        right: HollowSpacing.md,
      ),
      decoration: highlightDecoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?replyWidget,
          ?messageTextWidget,
          ?linkPreviewWidget,
          ?hollowLinkWidgets,
          ?fileWidget,
          ?reactionBarWidget,
        ],
      ),
    );
  }
}

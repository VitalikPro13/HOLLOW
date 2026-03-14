import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/channel_chat_message.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/chat/message_bubble.dart';
import 'package:haven/src/ui/chat/message_text_parser.dart';
import 'package:haven/src/ui/chat/reaction_bar.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';

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
  final void Function(String emoji)? onToggleReaction;

  const ChannelMessageBubble({
    super.key,
    required this.message,
    required this.serverId,
    required this.showHeader,
    this.replyToSenderName,
    this.replyToText,
    this.onToggleReaction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final nicknames = ref.watch(serverNicknamesProvider(serverId));
    final senderName = serverDisplayNameFor(
      profiles,
      message.senderId,
      nickname: nicknames[message.senderId] ?? '',
    );
    final isMe = message.isMe;
    final time =
        '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}';
    final isEdited = message.editedAt != null;

    const avatarSize = 32.0;
    const avatarGap = HavenSpacing.sm + 2; // 10px
    const indent = avatarSize + avatarGap;

    final hasReply = message.replyToMid != null && replyToText != null;

    final replyWidget = hasReply
        ? Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Container(
                  width: 2,
                  height: 28,
                  decoration: BoxDecoration(
                    color: haven.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        replyToSenderName ?? '',
                        style: HavenTypography.caption.copyWith(
                          color: haven.accent,
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                        ),
                      ),
                      Text(
                        replyToText!,
                        style: HavenTypography.caption.copyWith(
                          color: haven.textSecondary,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        : null;

    final localPeerId = ref.watch(identityProvider).peerId ?? '';

    final messageTextWidget = buildMessageText(
      message.text,
      context,
      suffixSpans: isEdited
          ? [
              TextSpan(
                text: ' (edited)',
                style: HavenTypography.caption.copyWith(
                  color: haven.textSecondary.withValues(alpha: 0.5),
                  fontSize: 10,
                ),
              ),
            ]
          : null,
    );

    final reactionBarWidget = message.reactions.isNotEmpty && onToggleReaction != null
        ? ReactionBar(
            reactions: message.reactions,
            localPeerId: localPeerId,
            onToggleReaction: onToggleReaction!,
          )
        : null;

    final meDecoration = BoxDecoration(
      border: Border(
        right: BorderSide(color: haven.accent, width: 2),
      ),
    );

    if (showHeader) {
      return Container(
        padding: const EdgeInsets.only(
          top: 4,
          bottom: 4,
          left: HavenSpacing.md,
          right: HavenSpacing.md,
        ),
        decoration: isMe ? meDecoration : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: HavenAvatar(peerId: message.senderId, size: avatarSize),
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
                        style: HavenTypography.body.copyWith(
                          color: isMe
                              ? haven.accent
                              : nameColorFromId(message.senderId),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: HavenSpacing.sm),
                      Text(
                        time,
                        style: HavenTypography.caption.copyWith(
                          color:
                              haven.textSecondary.withValues(alpha: 0.5),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  ?replyWidget,
                  messageTextWidget,
                  ?reactionBarWidget,
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Continuation message — indented, no avatar/name.
    return Container(
      padding: const EdgeInsets.only(
        top: 2,
        bottom: 2,
        left: HavenSpacing.md + indent,
        right: HavenSpacing.md,
      ),
      decoration: isMe ? meDecoration : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?replyWidget,
          messageTextWidget,
          ?reactionBarWidget,
        ],
      ),
    );
  }
}

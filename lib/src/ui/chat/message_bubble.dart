import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/chat_message.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/chat/message_text_parser.dart';
import 'package:haven/src/ui/chat/reaction_bar.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';

/// Deterministic name color from peer ID (same hue as avatar, lighter for readability).
Color nameColorFromId(String id) {
  final hash = id.hashCode;
  final hue = (hash % 360).abs().toDouble();
  return HSLColor.fromAHSL(1.0, hue, 0.6, 0.65).toColor();
}

/// Flat message row for DMs — no bubbles.
///
/// [showHeader] controls whether avatar + name + timestamp are shown
/// (first message in a group) or just indented text (continuation).
class MessageBubble extends ConsumerWidget {
  final ChatMessage message;
  final String peerId;
  final bool showHeader;
  final String? replyToSenderName;
  final String? replyToText;
  final void Function(String emoji)? onToggleReaction;

  const MessageBubble({
    super.key,
    required this.message,
    required this.peerId,
    required this.showHeader,
    this.replyToSenderName,
    this.replyToText,
    this.onToggleReaction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final isMe = message.isMe;
    final time =
        '${message.timestamp.hour.toString().padLeft(2, '0')}:${message.timestamp.minute.toString().padLeft(2, '0')}';
    final isEdited = message.editedAt != null;

    final profiles = ref.watch(profileProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final senderId = isMe ? localPeerId : peerId;
    final senderName = displayNameFor(profiles, senderId);

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
                child: HavenAvatar(peerId: senderId, size: avatarSize),
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
                                : nameColorFromId(senderId),
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

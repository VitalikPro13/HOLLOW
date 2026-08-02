import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/file_attachment_widget.dart';
import 'package:hollow/src/ui/chat/hollow_link_card.dart';
import 'package:hollow/src/ui/chat/bubble_perf.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/link_preview_card.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/chat/profile_tap.dart';
import 'package:hollow/src/ui/chat/reaction_bar.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';

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

  /// This message and its neighbour are BOTH sticker-only and grouped, so the
  /// seam between them is drawn continuous: no row padding, no corner
  /// rounding, no gap. See [stickerTilingFor] for how the panes decide.
  final bool tileWithPrev;
  final bool tileWithNext;

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
    this.tileWithPrev = false,
    this.tileWithNext = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Multi-device: a message's senderId may be a per-DEVICE peer id (public
    // channels store the raw frame author; older rows predate the Rust resolve).
    // Collapse device→master so the profile, nickname, name, avatar and colour all
    // key on the person — exactly like the member panel and DM path. Single-device
    // senders resolve to themselves (no-op); watching keeps the row reactive if the
    // device→master link arrives after first paint.
    final senderMaster =
        ref.watch(deviceLinkProvider).identityOf(message.senderId);
    final senderProfile = ref.watch(
        profileProvider.select((p) => p[senderMaster]));
    final senderNickname = ref.watch(
        serverNicknamesProvider(serverId).select((n) => n[senderMaster]));
    final senderName = serverDisplayNameForPeer(
      senderProfile,
      senderMaster,
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
              color: hollow.textSecondary.withValues(alpha: 0.5),
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
          if (replyToImagePath != null && cachedFileExists(replyToImagePath!))
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
            ? HollowFocusRing(
                enabled: onReplyTap != null,
                onActivate: onReplyTap,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onReplyTap,
                    child: replyContent,
                  ),
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
            tiling: (top: tileWithPrev, bottom: tileWithNext),
            suffixSpans: isEdited
                ? [
                    TextSpan(
                      text: ' (edited)',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textTertiary,
                        fontSize: 10,
                      ),
                    ),
                  ]
                : null,
          );

    final linkPreviewWidget = message.linkPreview != null
        ? Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xs),
            child: LinkPreviewCard(
              preview: message.linkPreview!,
              messageId: message.messageId,
            ),
          )
        : null;

    // Cheap contains() gate + hoisted regex — no per-row RegExp compile or
    // full-text scan for the overwhelmingly common no-link case.
    final hollowLinks = mightContainHollowLinks(message.text)
        ? extractHollowLinks(message.text.replaceAll(codeBlockRegex, ''))
        : const <HollowLink>[];
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
        padding: EdgeInsets.only(
          top: 4,
          // A group header never tiles upward (the run starts here), but it
          // can tile into the continuation below it.
          bottom: tileWithNext ? 0 : 4,
          left: HollowSpacing.md,
          right: HollowSpacing.md,
        ),
        decoration: highlightDecoration,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: ProfileTapTarget(
                peerId: senderMaster,
                nickname:
                    (senderNickname?.isNotEmpty ?? false) ? senderNickname : null,
                serverId: serverId,
                child: HollowAvatar(peerId: senderMaster, size: avatarSize),
              ),
            ),
            const SizedBox(width: avatarGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: ProfileTapTarget(
                          peerId: senderMaster,
                          nickname: (senderNickname?.isNotEmpty ?? false)
                              ? senderNickname
                              : null,
                          serverId: serverId,
                          child: Text(
                            senderName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HollowTypography.body.copyWith(
                              color: isMe
                                  ? hollow.accent
                                  : nameColorFromId(senderMaster),
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(
                        time,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textTertiary,
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

    // Continuation message — indented, no avatar/name. A tiled seam drops the
    // row padding on that side; the block asset drops its own to match.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(
        top: tileWithPrev ? 0 : 2,
        bottom: tileWithNext ? 0 : 2,
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/album_grouping.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/album_bubble.dart';
import 'package:hollow/src/ui/chat/bubble_perf.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/file_attachment_widget.dart';
import 'package:hollow/src/ui/chat/hollow_link_card.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/link_preview_card.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/chat/profile_tap.dart';
import 'package:hollow/src/ui/chat/reaction_bar.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:hollow/src/ui/components/support_glyph.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Avatar size in a message row; its column is also where a grouped
/// continuation shows its time on hover.
const double kMessageAvatarSize = 36;

/// Everything left of a message's text: the avatar column and its gap.
const double kMessageIndent = kMessageAvatarSize + HollowSpacing.md;

/// The compact display's time column, wide enough for `23:59` in mono.
const double _kCompactTimeWidth = 40;

/// The compact display's widest name before it ellipsizes.
const double _kCompactNameWidth = 160;

/// The one message row, for DMs, channels, the archive and the guest view.
///
/// [serverId] makes it a channel row: the sender resolves to their MASTER
/// with their server nickname, and mentions resolve against the members.
/// [showHeader] is false for a grouped continuation, which drops the avatar,
/// name and time (the time comes back on hover, in the avatar column).
class MessageRow extends ConsumerWidget {
  final String? messageId;
  final String senderId;
  final bool isMe;
  final String text;
  final DateTime timestamp;
  final DateTime? editedAt;
  final String? replyToMid;
  final Map<String, List<String>> reactions;
  final FileAttachment? fileAttachment;
  final network_api.LinkPreviewRef? linkPreview;
  final String? serverId;
  final bool showHeader;
  final String? replyToSenderId;
  final String? replyToSenderName;
  final String? replyToText;
  final String? replyToImagePath;
  final bool isHighlighted;
  final bool isMentioned;
  final VoidCallback? onReplyTap;
  final void Function(String emoji)? onToggleReaction;

  /// This message and its neighbour are BOTH sticker-only and grouped, so the
  /// seam is drawn continuous and a run becomes one tall image (see
  /// [stickerTilingFor]).
  final bool tileWithPrev;
  final bool tileWithNext;

  /// Every item of the album this message anchors, itself first. Null for a
  /// message that renders on its own.
  final List<AlbumItem>? album;

  const MessageRow({
    super.key,
    required this.messageId,
    required this.senderId,
    required this.isMe,
    required this.text,
    required this.timestamp,
    required this.editedAt,
    required this.replyToMid,
    required this.reactions,
    required this.fileAttachment,
    required this.linkPreview,
    required this.showHeader,
    this.serverId,
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
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final links = ref.watch(deviceLinkProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    // A sender may be a per-DEVICE id: public channels store the raw frame
    // author and older rows predate the Rust resolve. Everything keys on the
    // MASTER, and watching keeps the row live when the link arrives late.
    final sender = links.identityOf(senderId);
    final serverId = this.serverId;
    final profile = ref.watch(profileProvider.select((p) => p[sender]));
    final nickname = serverId == null
        ? null
        : ref.watch(
            serverNicknamesProvider(serverId).select((n) => n[sender]));
    final senderName = serverId == null
        ? displayNameForPeer(profile, sender)
        : serverDisplayNameForPeer(profile, sender, nickname: nickname ?? '');
    final tapNickname = (nickname?.isNotEmpty ?? false) ? nickname : null;
    final memberNames =
        serverId == null ? null : ref.watch(serverMemberNamesProvider(serverId));

    final time = _clock(timestamp);
    final reply = _buildReply(hollow, links.identityOf(localPeerId), links);

    // A file placeholder carries no text of its own. An album shows its
    // caption whichever item carries it.
    final albumItems = album;
    final shownText = albumItems == null
        ? text
        : albumCaption([for (final i in albumItems) i.text]);
    final isFileOnly = fileAttachment != null &&
        (shownText.isEmpty || shownText.startsWith('[file:'));

    // Cheap gate first: no per-row RegExp compile or full-text scan for the
    // overwhelmingly common no-link message.
    final hollowLinks = mightContainHollowLinks(shownText)
        ? extractHollowLinks(shownText.replaceAll(codeBlockRegex, ''))
        : const <HollowLink>[];

    final body = <Widget>[
      ?reply,
      if (!isFileOnly)
        buildMessageText(
          shownText,
          context,
          memberNames: memberNames,
          tiling: (top: tileWithPrev, bottom: tileWithNext),
          suffixSpans: editedAt != null
              ? [
                  TextSpan(
                    text: ' (edited)',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textTertiary),
                  ),
                ]
              : null,
        ),
      if (linkPreview != null)
        _attached(LinkPreviewCard(preview: linkPreview!, messageId: messageId)),
      for (final link in hollowLinks.take(3)) _attached(HollowLinkCard(link: link)),
      if (albumItems != null)
        _attached(AlbumBubble(items: albumItems))
      else if (fileAttachment != null)
        _attached(FileAttachmentWidget(
          attachment: fileAttachment!,
          messageId: messageId,
          senderId: sender,
          timestampMs: timestamp.millisecondsSinceEpoch,
          isMine: isMe,
        )),
      if (reactions.isNotEmpty)
        ReactionBar(
          reactions: reactions,
          localPeerId: localPeerId,
          onToggleReaction: onToggleReaction,
        ),
    ];

    final wash = isHighlighted || isMentioned
        ? BoxDecoration(color: hollow.accent.withValues(alpha: 0.08))
        : null;

    Widget toProfile(Widget child) => ProfileTapTarget(
          peerId: sender,
          nickname: tapNickname,
          serverId: serverId,
          child: child,
        );
    final nameStyle =
        (isTouchForm ? HollowTypography.bodyTouch : HollowTypography.body)
            .copyWith(
      color: isMe ? hollow.accentText : nameColorFor(sender, hollow),
      fontWeight: FontWeight.w600,
    );

    if (ref.watch(messageDisplayProvider) == MessageDisplay.compact) {
      // Every row carries its own time and name, so a grouped run reads the
      // same as the first line of it.
      return AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        decoration: wash,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.xxs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            SizedBox(
              width: _kCompactTimeWidth,
              child: Text(time,
                  textAlign: TextAlign.right, style: _timeStyle(hollow)),
            ),
            const SizedBox(width: HollowSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kCompactNameWidth),
              child: toProfile(Text(
                senderName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: nameStyle,
              )),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: body,
              ),
            ),
          ],
        ),
      );
    }

    if (!showHeader) {
      // A tiled seam drops the row padding on that side, and the block asset
      // drops its own to match.
      return AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOut,
        decoration: wash,
        padding: EdgeInsets.only(
          top: tileWithPrev ? 0 : HollowSpacing.xxs,
          bottom: tileWithNext ? 0 : HollowSpacing.xxs,
          left: HollowSpacing.lg,
          right: HollowSpacing.lg,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: kMessageAvatarSize, child: _HoverTime(time)),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: body,
              ),
            ),
          ],
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      decoration: wash,
      padding: EdgeInsets.only(
        top: HollowSpacing.xs,
        // A group header starts the run, so it never tiles upward.
        bottom: tileWithNext ? 0 : HollowSpacing.xxs,
        left: HollowSpacing.lg,
        right: HollowSpacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xxs),
            child: toProfile(
                HollowAvatar(peerId: sender, size: kMessageAvatarSize)),
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: toProfile(Text(
                        senderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle,
                      )),
                    ),
                    // Opt-in by the holder, a shrunk box for everyone else.
                    SupportNameGlyph(peerId: sender),
                    const SizedBox(width: HollowSpacing.sm),
                    Text(time, style: _timeStyle(hollow)),
                  ],
                ),
                ...body,
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One line above the message: who it answers and what they said.
  Widget? _buildReply(HollowTheme hollow, String me, DeviceLinkState links) {
    final replyText = replyToText;
    if (replyToMid == null || replyText == null) return null;
    final replySender =
        replyToSenderId == null ? null : links.identityOf(replyToSenderId!);
    final nameColor = replySender == null
        ? hollow.textSecondary
        : replySender == me
            ? hollow.accentText
            : nameColorFor(replySender, hollow);
    final image = replyToImagePath;
    final line = Row(
      children: [
        Icon(LucideIcons.reply, size: 14, color: hollow.textTertiary),
        const SizedBox(width: HollowSpacing.xs),
        if (replyToSenderName != null) ...[
          Text(
            replyToSenderName!,
            style: HollowTypography.bodySmall
                .copyWith(color: nameColor, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: HollowSpacing.xs),
        ],
        Flexible(
          child: Text(
            replyText,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
          ),
        ),
        if (image != null && cachedFileExists(image)) ...[
          const SizedBox(width: HollowSpacing.xs),
          ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusXs),
            child: AttachmentImage(
              path: image,
              animated: image.toLowerCase().endsWith('.gif'),
              width: HollowSpacing.lg,
              height: HollowSpacing.lg,
              fit: BoxFit.cover,
            ),
          ),
        ],
      ],
    );
    final tap = onReplyTap;
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xxs),
      child: tap == null
          ? line
          : HollowFocusRing(
              onActivate: tap,
              borderRadius: BorderRadius.circular(hollow.radiusXs),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(onTap: tap, child: line),
              ),
            ),
    );
  }
}

/// Space between the text and what hangs under it (a card, a file, a link).
Widget _attached(Widget child) => Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xs),
      child: child,
    );

String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

TextStyle _timeStyle(HollowTheme hollow) => HollowTypography.monoSmall.copyWith(
      color: hollow.textTertiary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

/// A grouped continuation's time, shown only while its row is hovered.
class _HoverTime extends StatelessWidget {
  final String time;
  const _HoverTime(this.time);

  @override
  Widget build(BuildContext context) {
    if (HoverScope.maybeOf(context) != true) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xxs),
      child: Text(
        time,
        textAlign: TextAlign.right,
        style: _timeStyle(HollowTheme.of(context)),
      ),
    );
  }
}

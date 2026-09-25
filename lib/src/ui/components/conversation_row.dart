import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/status_dot.dart';

/// One conversation in a list: a DM, or a channel that mentioned us.
///
/// The one row for this kind of thing (design language 5.3, check 8): Home, the
/// sidebar, mobile Chats and the Archive draw a conversation with this, never
/// their own.
class ConversationRow extends StatelessWidget {
  final Widget leading;
  final String title;

  /// Quiet text after the title, such as the server a channel belongs to.
  final String? detail;

  final String preview;

  /// Prefixes the preview with "You: ".
  final bool fromMe;

  final String? time;
  final int unread;
  final bool mention;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Phone metrics: type one step up and a full-bleed row about 72 tall
  /// (design language 5.4). Pass a 48 px leading with it.
  final bool touch;

  /// Replaces the preview line with something happening now (the call you
  /// are in with them); [liveLabel] says it to screen readers.
  final Widget? live;
  final String? liveLabel;

  const ConversationRow({
    super.key,
    required this.leading,
    required this.title,
    required this.preview,
    required this.onTap,
    this.onLongPress,
    this.detail,
    this.fromMe = false,
    this.time,
    this.unread = 0,
    this.mention = false,
    this.touch = false,
    this.live,
    this.liveLabel,
  });

  bool get _hot => unread > 0 || mention;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final quiet = hollow.textSecondary;
    final titleStyle = touch ? HollowTypography.subheading : HollowTypography.body;
    final previewStyle = touch ? HollowTypography.body : HollowTypography.bodySmall;
    final metaStyle = touch ? HollowTypography.bodySmall : HollowTypography.caption;
    return HollowPressable(
        onTap: onTap,
        onLongPress: onLongPress,
        subtle: true,
        semanticButton: false,
        semanticLabel: _semanticLabel,
        borderRadius:
            touch ? BorderRadius.zero : BorderRadius.circular(hollow.radiusMd),
        padding: touch
            ? const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg, vertical: HollowSpacing.md)
            : const EdgeInsets.all(HollowSpacing.sm),
        child: Row(
          children: [
            leading,
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: titleStyle.copyWith(
                            color: hollow.textPrimary,
                            fontWeight:
                                _hot ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (detail != null) ...[
                        const SizedBox(width: HollowSpacing.xs),
                        Text(
                          detail!,
                          maxLines: 1,
                          style: HollowTypography.bodySmall
                              .copyWith(color: hollow.textTertiary),
                        ),
                      ],
                      // Beside the name, not at the row's far end: on a wide
                      // pane the eye would travel the whole row to read it.
                      if (time != null) ...[
                        const SizedBox(width: HollowSpacing.sm),
                        Text(
                          time!,
                          maxLines: 1,
                          style: metaStyle.copyWith(
                            color: hollow.textTertiary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (live != null)
                    DefaultTextStyle.merge(style: previewStyle, child: live!)
                  else
                  Text.rich(
                    TextSpan(children: [
                      if (fromMe)
                        TextSpan(
                          text: 'You: ',
                          style: TextStyle(color: quiet),
                        ),
                      TextSpan(text: preview),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: previewStyle.copyWith(
                      color: _hot ? hollow.textPrimary : quiet,
                    ),
                  ),
                ],
              ),
            ),
            if (_hot) ...[
              const SizedBox(width: HollowSpacing.md),
              HollowCountBadge(count: unread, mention: mention),
            ],
          ],
        ),
    );
  }

  String get _semanticLabel {
    final parts = [
      title,
      ?detail,
      if (mention) 'mentioned you' else if (unread > 0) '$unread unread',
      liveLabel ?? preview,
    ];
    return parts.join(', ');
  }
}

/// An avatar with its presence dot cut into the corner, for list rows.
class PresenceAvatar extends StatelessWidget {
  final String peerId;
  final double size;
  final bool online;

  /// The surface the row sits on, which the dot's ring is cut from.
  final Color ring;

  const PresenceAvatar({
    super.key,
    required this.peerId,
    required this.size,
    required this.online,
    required this.ring,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dot = size >= 44 ? 10.0 : (size >= 36 ? 8.0 : 7.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          HollowAvatar(peerId: peerId, size: size),
          Positioned(
            right: -HollowSpacing.xxs,
            bottom: -HollowSpacing.xxs,
            child: Container(
              padding: const EdgeInsets.all(HollowSpacing.xxs),
              decoration: BoxDecoration(color: ring, shape: BoxShape.circle),
              child: StatusDot(
                color: online ? hollow.success : hollow.textTertiary,
                size: dot,
                filled: online,
                semanticLabel: online ? 'Online' : 'Offline',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

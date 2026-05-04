import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/selection_shimmer.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

class PeerCard extends ConsumerWidget {
  final String peerId;
  final bool isSelected;
  final bool isEncrypted;
  final bool isOnline;
  final ChatMessage? lastMessage;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;

  const PeerCard({
    super.key,
    required this.peerId,
    required this.isSelected,
    required this.isEncrypted,
    this.isOnline = true,
    required this.lastMessage,
    required this.formatTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final peerName = displayNameFor(profiles, peerId);
    final radius = BorderRadius.circular(hollow.radiusMd);
    final isDmMuted = !ref.watch(notificationSettingsProvider.notifier)
        .isDmEnabled(peerId);
    final hasUnread = !isSelected &&
        !isDmMuted &&
        ref.watch(unreadProvider.notifier).isDmUnread(peerId);

    Widget card = HollowPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: radius,
      backgroundColor:
          isSelected ? hollow.accentMuted : Colors.transparent,
      hoverColor: hollow.elevated,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm + 2,
        ),
        child: AnimatedContainer(
          duration: HollowDurations.fast,
          curve: HollowCurves.subtle,
          child: Row(
            children: [
              // Avatar with status dot overlay
              Stack(
                children: [
                  HollowAvatar(peerId: peerId, size: 36),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: hollow.background,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(1.5),
                      child: StatusDot(
                        color: isOnline ? hollow.success : hollow.textSecondary,
                        size: 8,
                        pulse: isOnline,
                      ),
                    ),
                  ),
                ],
              ),
              if (isEncrypted) ...[
                const SizedBox(width: HollowSpacing.xs),
                Icon(
                  LucideIcons.lock,
                  size: 12,
                  color: hollow.success,
                ),
              ],
              const SizedBox(width: HollowSpacing.sm + 2),
              // Peer info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peerName,
                      style: HollowTypography.body.copyWith(
                        fontSize: 13,
                        fontWeight: isSelected || hasUnread
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: hollow.textPrimary,
                      ),
                    ),
                    if (lastMessage != null) ...[
                      const SizedBox(height: HollowSpacing.xxs),
                      Text(
                        lastMessage!.isMe
                            ? 'You: ${lastMessage!.text}'
                            : lastMessage!.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.bodySmall.copyWith(
                          color: hollow.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Timestamp + unread dot
              if (lastMessage != null || hasUnread)
                Padding(
                  padding:
                      const EdgeInsets.only(left: HollowSpacing.sm),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (lastMessage != null)
                        Text(
                          formatTime(lastMessage!.timestamp),
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          ),
                        ),
                      if (hasUnread) ...[
                        const SizedBox(width: HollowSpacing.xs),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: hollow.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      );

    if (isSelected) {
      card = SelectionShimmer(
        highlightColor: hollow.accent.withValues(alpha: 0.12),
        borderRadius: radius,
        child: card,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: card,
    );
  }
}

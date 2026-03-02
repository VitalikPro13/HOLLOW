import 'package:flutter/material.dart';
import 'package:haven/src/core/models/chat_message.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

class PeerCard extends StatelessWidget {
  final String peerId;
  final bool isSelected;
  final bool isEncrypted;
  final ChatMessage? lastMessage;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;

  const PeerCard({
    super.key,
    required this.peerId,
    required this.isSelected,
    required this.isEncrypted,
    required this.lastMessage,
    required this.formatTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm,
        vertical: HavenSpacing.xxs,
      ),
      child: HavenPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(haven.radiusMd),
        backgroundColor:
            isSelected ? haven.accentMuted : Colors.transparent,
        hoverColor: haven.elevated,
        padding: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.md,
          vertical: HavenSpacing.sm + 2,
        ),
        child: AnimatedContainer(
          duration: HavenDurations.fast,
          curve: HavenCurves.subtle,
          child: Row(
            children: [
              // Avatar with status dot overlay
              Stack(
                children: [
                  HavenAvatar(peerId: peerId, size: 36),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: haven.background,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(1.5),
                      child: StatusDot(
                        color: haven.success,
                        size: 8,
                      ),
                    ),
                  ),
                ],
              ),
              if (isEncrypted) ...[
                const SizedBox(width: HavenSpacing.xs),
                Icon(
                  LucideIcons.lock,
                  size: 12,
                  color: haven.success,
                ),
              ],
              const SizedBox(width: HavenSpacing.sm + 2),
              // Peer info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peerId.length > 16
                          ? '${peerId.substring(0, 16)}...'
                          : peerId,
                      style: HavenTypography.body.copyWith(
                        fontFamily: 'Consolas',
                        fontSize: 13,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: haven.textPrimary,
                      ),
                    ),
                    if (lastMessage != null) ...[
                      const SizedBox(height: HavenSpacing.xxs),
                      Text(
                        lastMessage!.isMe
                            ? 'You: ${lastMessage!.text}'
                            : lastMessage!.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: HavenTypography.bodySmall.copyWith(
                          color: haven.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Timestamp
              if (lastMessage != null)
                Padding(
                  padding:
                      const EdgeInsets.only(left: HavenSpacing.sm),
                  child: Text(
                    formatTime(lastMessage!.timestamp),
                    style: HavenTypography.caption.copyWith(
                      color: haven.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

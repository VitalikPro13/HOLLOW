import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/channel_chat_message.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_transitions.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';

class ChannelMessageBubble extends ConsumerWidget {
  final ChannelChatMessage message;
  final String serverId;

  const ChannelMessageBubble({
    super.key,
    required this.message,
    required this.serverId,
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

    return FadeSlideTransition(
      beginOffset: Offset(isMe ? 0.05 : -0.05, 0.0),
      duration: const Duration(milliseconds: 200),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HavenSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isMe) ...[
              HavenAvatar(peerId: message.senderId, size: 28),
              const SizedBox(width: HavenSpacing.sm),
            ],
            Flexible(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.5,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: HavenSpacing.md + 2,
                  vertical: HavenSpacing.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: isMe ? haven.accent : haven.elevated,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(haven.radiusLg),
                    topRight: Radius.circular(haven.radiusLg),
                    bottomLeft: Radius.circular(
                        isMe ? haven.radiusLg : haven.radiusSm),
                    bottomRight: Radius.circular(
                        isMe ? haven.radiusSm : haven.radiusLg),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: isMe
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!isMe)
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: HavenSpacing.xs),
                        child: Text(
                          senderName,
                          style: HavenTypography.caption.copyWith(
                            color: haven.accent,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Text(
                      message.text,
                      style: HavenTypography.body.copyWith(
                        color: isMe ? haven.textOnAccent : haven.textPrimary,
                      ),
                    ),
                    const SizedBox(height: HavenSpacing.xs),
                    Text(
                      time,
                      style: HavenTypography.caption.copyWith(
                        color: isMe
                            ? haven.textOnAccent.withValues(alpha: 0.7)
                            : haven.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

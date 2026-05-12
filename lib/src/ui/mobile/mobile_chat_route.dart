import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons/lucide_icons.dart';

class MobileChatRoute extends ConsumerWidget {
  final String? peerId;
  final String? serverId;
  final String? channelId;
  final String? channelName;

  const MobileChatRoute({
    super.key,
    this.peerId,
    this.serverId,
    this.channelId,
    this.channelName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            _MobileChatHeader(
              peerId: peerId,
              channelName: channelName,
            ),
            Expanded(
              child: peerId != null
                  ? ChatPane(
                      key: ValueKey(peerId),
                      peerId: peerId!,
                    )
                  : ChannelChatPane(
                      key: ValueKey('ch:$channelId'),
                      serverId: serverId!,
                      channelId: channelId!,
                      channelName: channelName ?? 'Channel',
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileChatHeader extends ConsumerWidget {
  final String? peerId;
  final String? channelName;

  const _MobileChatHeader({this.peerId, this.channelName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);

    String title;
    if (peerId != null) {
      title = displayNameFor(profiles, peerId!);
    } else {
      title = '# ${channelName ?? 'Channel'}';
    }

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
      child: Row(
        children: [
          HollowPressable(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(
              LucideIcons.arrowLeft,
              size: 20,
              color: hollow.textPrimary,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (peerId != null)
            HollowAvatar(peerId: peerId!, size: 28),
          if (peerId != null) const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              title,
              style: HollowTypography.body.copyWith(
                fontWeight: FontWeight.w600,
                color: hollow.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

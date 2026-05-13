import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:hollow/src/core/providers/room_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/share/paste_link_dialog.dart';
import 'package:hollow/src/ui/share/share_card.dart';

class HollowLinkCard extends ConsumerWidget {
  final HollowLink link;
  const HollowLinkCard({super.key, required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (link.type) {
      case HollowLinkType.share:
        return _ShareLinkCard(link: link);
      case HollowLinkType.serverInvite:
        return _ServerInviteCard(link: link);
      case HollowLinkType.roomInvite:
        return _RoomInviteCard(link: link);
    }
  }
}

Widget _cardContainer({
  required HollowTheme hollow,
  required VoidCallback? onTap,
  required Widget child,
}) {
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 400),
    child: HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: Container(
          decoration: BoxDecoration(
            color: hollow.elevated,
            border: Border(
              left: BorderSide(color: hollow.accent, width: 3),
              top: BorderSide(color: hollow.border),
              right: BorderSide(color: hollow.border),
              bottom: BorderSide(color: hollow.border),
            ),
          ),
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: child,
        ),
      ),
    ),
  );
}

class _ShareLinkCard extends ConsumerWidget {
  final HollowLink link;
  const _ShareLinkCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final shares = ref.watch(shareTabProvider);
    final existing = shares.where((s) => s.shareLink == link.fullUrl).firstOrNull;

    return _cardContainer(
      hollow: hollow,
      onTap: () => _openShareDialog(context),
      child: Row(
        children: [
          Icon(LucideIcons.share2, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  existing != null ? existing.fileName : 'Hollow Share',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (existing != null)
                  Text(
                    '${ShareCard.formatSize(existing.totalSize)}  ·  ${existing.chunksTotal} chunks',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    'Click to download',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (existing != null)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: hollow.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              child: Text(
                'In shares',
                style: HollowTypography.caption.copyWith(
                  color: hollow.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            HollowButton.outline(
              compact: true,
              onPressed: () => _openShareDialog(context),
              child: const Text('Open'),
            ),
        ],
      ),
    );
  }

  void _openShareDialog(BuildContext context) {
    showHollowDialog(
      context: context,
      builder: (ctx) => PasteLinkDialog(initialLink: link.fullUrl),
    );
  }
}

class _ServerInviteCard extends ConsumerWidget {
  final HollowLink link;
  const _ServerInviteCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider);
    final serverInfo = servers[link.id];
    final alreadyJoined = serverInfo != null;

    return _cardContainer(
      hollow: hollow,
      onTap: alreadyJoined ? null : () => _handleJoin(context),
      child: Row(
        children: [
          Icon(LucideIcons.server, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  alreadyJoined ? serverInfo.name : 'Server Invite',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (alreadyJoined)
                  Text(
                    '${serverInfo.memberCount} ${serverInfo.memberCount == 1 ? 'member' : 'members'}  ·  ${serverInfo.channelCount} ${serverInfo.channelCount == 1 ? 'channel' : 'channels'}',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  )
                else
                  Text(
                    link.id,
                    style: HollowTypography.mono.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (alreadyJoined)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: hollow.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              child: Text(
                'Joined',
                style: HollowTypography.caption.copyWith(
                  color: hollow.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            HollowButton.filled(
              compact: true,
              onPressed: () => _handleJoin(context),
              child: const Text('Join'),
            ),
        ],
      ),
    );
  }

  void _handleJoin(BuildContext context) {
    crdt_api.joinServer(serverId: link.id);
    HollowToast.show(context, 'Joining server...', type: HollowToastType.info);
  }
}

class _RoomInviteCard extends ConsumerWidget {
  final HollowLink link;
  const _RoomInviteCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return _cardContainer(
      hollow: hollow,
      onTap: () => _handleJoin(ref),
      child: Row(
        children: [
          Icon(LucideIcons.messageCircle, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Room Invite',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  link.id,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            compact: true,
            onPressed: () => _handleJoin(ref),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  void _handleJoin(WidgetRef ref) {
    ref.read(roomProvider.notifier).join(link.fullUrl);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Blocked-users pieces shared by the desktop Security category and the mobile
/// Blocked Users tab. The list is master-keyed and purely local: Rust drops
/// their DMs, requests and calls at ingest.

/// Explainer shown above the blocked list on both surfaces.
Widget blockedUsersIntro(HollowTheme hollow) {
  return Text(
    'Blocked users can\'t send you friend requests, direct messages, '
    'or calls, and their channel messages are hidden.',
    style: HollowTypography.caption.copyWith(
      color: hollow.textSecondary,
    ),
  );
}

/// One blocked-user row. Avatar size and id formatting differ per surface, so
/// they are passed in.
class BlockedUserRow extends ConsumerWidget {
  final String id;
  final double avatarSize;
  final String shortId;

  const BlockedUserRow({
    super.key,
    required this.id,
    required this.avatarSize,
    required this.shortId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          HollowAvatar(peerId: id, size: avatarSize),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayNameForPeer(profiles[id], id),
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  shortId,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            compact: true,
            onPressed: () async {
              try {
                await ref.read(blockedUsersProvider.notifier).unblock(id);
              } catch (_) {
                if (context.mounted) {
                  HollowToast.show(context, 'Failed to unblock',
                      type: HollowToastType.error);
                }
              }
            },
            child: const Text('Unblock'),
          ),
        ],
      ),
    );
  }
}

/// The blocked list inside a [SettingsCard], for the desktop Security category.
class BlockedUsersCard extends ConsumerWidget {
  const BlockedUsersCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final blocked = ref.watch(blockedUsersProvider).toList()..sort();

    return SettingsCard(
      title: 'Blocked Users',
      children: [
        if (blocked.isEmpty)
          Text(
            'No blocked users.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          )
        else ...[
          blockedUsersIntro(hollow),
          const SizedBox(height: HollowSpacing.sm),
          for (final id in blocked)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
              child: BlockedUserRow(
                id: id,
                avatarSize: 32,
                shortId: shortenPeerId(id),
              ),
            ),
        ],
      ],
    );
  }
}

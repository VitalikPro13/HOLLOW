import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:lucide_icons/lucide_icons.dart';

class MobileFriendsTab extends ConsumerWidget {
  const MobileFriendsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final friends = ref.watch(friendsProvider);
    final peers = ref.watch(peersProvider);
    final profiles = ref.watch(profileProvider);

    debugPrint('[MOBILE-FRIENDS] Provider has ${friends.length} entries: ${friends.values.map((f) => '${f.peerId.substring(0, 12)}...(${f.status}/${f.direction})').join(', ')}');

    final accepted = <FriendInfo>[];
    final incoming = <FriendInfo>[];
    final outgoing = <FriendInfo>[];

    for (final f in friends.values) {
      if (f.status == 'accepted') {
        accepted.add(f);
      } else if (f.status == 'pending' && f.direction == 'incoming') {
        incoming.add(f);
      } else if (f.status == 'pending' && f.direction == 'outgoing') {
        outgoing.add(f);
      }
    }

    accepted.sort((a, b) {
      final aOnline = peers.containsKey(a.peerId) ? 0 : 1;
      final bOnline = peers.containsKey(b.peerId) ? 0 : 1;
      if (aOnline != bOnline) return aOnline.compareTo(bOnline);
      return displayNameFor(profiles, a.peerId)
          .compareTo(displayNameFor(profiles, b.peerId));
    });

    final hasPending = incoming.isNotEmpty || outgoing.isNotEmpty;

    return CustomScrollView(
      slivers: [
        // Add Friend button
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.lg,
              HollowSpacing.lg, HollowSpacing.sm,
            ),
            child: HollowButton.outline(
              onPressed: () => _showAddFriendDialog(context, ref),
              icon: const Icon(LucideIcons.userPlus, size: 16),
              expand: true,
              child: const Text('Add Friend'),
            ),
          ),
        ),

        // Pending requests
        if (hasPending) ...[
          _SectionHeader(label: 'REQUESTS', count: incoming.length + outgoing.length),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index < incoming.length) {
                  return _PendingRow(peerId: incoming[index].peerId, isIncoming: true);
                }
                return _PendingRow(peerId: outgoing[index - incoming.length].peerId, isIncoming: false);
              },
              childCount: incoming.length + outgoing.length,
            ),
          ),
        ],

        // Friends
        _SectionHeader(label: 'FRIENDS', count: accepted.length),

        if (accepted.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg, vertical: HollowSpacing.xxl,
              ),
              child: Center(
                child: Column(
                  children: [
                    Icon(LucideIcons.users, size: 40,
                        color: hollow.textSecondary.withValues(alpha: 0.4)),
                    const SizedBox(height: HollowSpacing.md),
                    Text('No friends yet',
                        style: HollowTypography.body.copyWith(color: hollow.textSecondary)),
                    const SizedBox(height: HollowSpacing.xs),
                    Text('Add a friend by their peer ID', style: HollowTypography.bodySmall),
                  ],
                ),
              ),
            ),
          )
        else
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final friend = accepted[index];
                final isOnline = peers.containsKey(friend.peerId);
                final name = displayNameFor(profiles, friend.peerId);
                return _FriendRow(
                  peerId: friend.peerId,
                  name: name,
                  isOnline: isOnline,
                  onTap: () {
                    ref.read(selectedPeerProvider.notifier).state = friend.peerId;
                    Navigator.of(context, rootNavigator: true).push(
                      MaterialPageRoute(
                        builder: (_) => MobileChatRoute(peerId: friend.peerId),
                      ),
                    );
                  },
                );
              },
              childCount: accepted.length,
            ),
          ),

        const SliverPadding(padding: EdgeInsets.only(bottom: HollowSpacing.xl)),
      ],
    );
  }

  void _showAddFriendDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showHollowDialog(
      context: context,
      builder: (_) => _AddFriendDialog(controller: controller),
    );
  }
}

// ─────────────────────────────────────────────────
// Section header
// ─────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;

  const _SectionHeader({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(child: Divider(color: hollow.border, height: 1)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
              child: Text(
                '$label  $count',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            Expanded(child: Divider(color: hollow.border, height: 1)),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Friend row
// ─────────────────────────────────────────────────

class _FriendRow extends StatelessWidget {
  final String peerId;
  final String name;
  final bool isOnline;
  final VoidCallback onTap;

  const _FriendRow({
    required this.peerId,
    required this.name,
    required this.isOnline,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 40, height: 40,
            child: Stack(
              children: [
                HollowAvatar(peerId: peerId, size: 40),
                Positioned(
                  right: 0, bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: hollow.background, shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(1.5),
                    child: StatusDot(
                      color: isOnline ? hollow.success : hollow.textSecondary,
                      size: 10, pulse: isOnline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary, fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(isOnline ? 'Online' : 'Offline',
                    style: HollowTypography.bodySmall.copyWith(
                      color: isOnline ? hollow.success : hollow.textSecondary,
                    )),
              ],
            ),
          ),
          Icon(LucideIcons.messageCircle, size: 18, color: hollow.textSecondary),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Pending request row
// ─────────────────────────────────────────────────

class _PendingRow extends ConsumerWidget {
  final String peerId;
  final bool isIncoming;

  const _PendingRow({required this.peerId, required this.isIncoming});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final name = displayNameFor(profiles, peerId);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          HollowAvatar(peerId: peerId, size: 40),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary, fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(isIncoming ? 'Wants to be friends' : 'Request sent',
                    style: HollowTypography.bodySmall.copyWith(
                      color: hollow.textSecondary,
                    )),
              ],
            ),
          ),
          if (isIncoming) ...[
            HollowPressable(
              onTap: () {
                ref.read(friendsProvider.notifier).acceptRequest(peerId);
                HollowToast.show(context, 'Friend request accepted',
                    type: HollowToastType.success);
              },
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Icon(LucideIcons.check, size: 20, color: hollow.success),
            ),
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: () => ref.read(friendsProvider.notifier).rejectRequest(peerId),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Icon(LucideIcons.x, size: 20, color: hollow.error),
            ),
          ] else
            // Cancel outgoing request
            HollowPressable(
              onTap: () => ref.read(friendsProvider.notifier).rejectRequest(peerId),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Icon(LucideIcons.x, size: 18, color: hollow.textSecondary),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Add Friend dialog (uses showHollowDialog for blur + animation)
// ─────────────────────────────────────────────────

class _AddFriendDialog extends ConsumerStatefulWidget {
  final TextEditingController controller;

  const _AddFriendDialog({required this.controller});

  @override
  ConsumerState<_AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends ConsumerState<_AddFriendDialog> {
  bool _sending = false;

  Future<void> _send() async {
    final peerId = widget.controller.text.trim();
    if (peerId.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(friendsProvider.notifier).sendRequest(peerId);
      if (mounted) {
        Navigator.of(context).pop();
        HollowToast.show(context, 'Friend request sent',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to send request',
            type: HollowToastType.error);
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Add Friend',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Paste their peer ID to send a friend request.',
              style: HollowTypography.bodySmall),
          const SizedBox(height: HollowSpacing.lg),
          TextField(
            controller: widget.controller,
            autofocus: true,
            style: HollowTypography.mono.copyWith(
              color: hollow.textPrimary, fontSize: 12,
            ),
            decoration: InputDecoration(
              hintText: 'Paste peer ID...',
              hintStyle: HollowTypography.mono.copyWith(
                color: hollow.textSecondary, fontSize: 12,
              ),
              filled: true,
              fillColor: hollow.surface,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md, vertical: HollowSpacing.md,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.accent),
              ),
            ),
            onSubmitted: (_) => _send(),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _sending ? null : _send,
          child: Text(_sending ? 'Sending...' : 'Send Request'),
        ),
      ],
    );
  }
}

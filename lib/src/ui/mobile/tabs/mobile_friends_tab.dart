import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/temporary_nickname_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileFriendsTab extends ConsumerStatefulWidget {
  const MobileFriendsTab({super.key});

  @override
  ConsumerState<MobileFriendsTab> createState() => _MobileFriendsTabState();
}

class _MobileFriendsTabState extends ConsumerState<MobileFriendsTab> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchQuery = _searchController.text.toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final friends = ref.watch(friendsProvider);
    final online = ref.watch(onlineIdentitiesProvider);
    ref.watch(profileProvider);
    final favourites = ref.watch(favouriteFriendsProvider);
    final links = ref.watch(deviceLinkProvider);
    ref.watch(localNicknameProvider);

    // Accepted friends come master-collapsed + deduped from the shared provider
    // (parity with desktop) so a friend stranded under a DEVICE id doesn't appear
    // twice or under a raw id. Pending requests stay raw (their device→master
    // mapping usually isn't known until after acceptance).
    final accepted = ref.watch(sortedFriendsProvider);
    final incoming = <FriendInfo>[];
    final outgoing = <FriendInfo>[];

    for (final f in friends.values) {
      if (f.status == 'pending' && f.direction == 'incoming') {
        incoming.add(f);
      } else if (f.status == 'pending' && f.direction == 'outgoing') {
        outgoing.add(f);
      }
    }

    // Favourite ids are resolved device→master before matching, so a favourite
    // saved under a device id still matches its (collapsed) friend row.
    final favMasters = favourites.map(links.identityOf).toList();
    int favRank(String peerId) {
      final i = favMasters.indexOf(peerId);
      return i < 0 ? favMasters.length : i;
    }
    bool isFav(String peerId) => favMasters.contains(peerId);

    // Separate favourites from non-favourites
    final favFriends = <FriendInfo>[];
    final onlineFriends = <FriendInfo>[];
    final offlineFriends = <FriendInfo>[];

    for (final f in accepted) {
      final name = _resolvedName(f.peerId);
      if (_searchQuery.isNotEmpty && !name.toLowerCase().contains(_searchQuery)) continue;

      if (isFav(f.peerId)) {
        favFriends.add(f);
      } else if (online.contains(f.peerId)) {
        onlineFriends.add(f);
      } else {
        offlineFriends.add(f);
      }
    }

    // Sort favourites by fav order, others alphabetically
    favFriends.sort((a, b) => favRank(a.peerId).compareTo(favRank(b.peerId)));

    int sortByName(FriendInfo a, FriendInfo b) =>
        _resolvedName(a.peerId)
            .compareTo(_resolvedName(b.peerId));
    onlineFriends.sort(sortByName);
    offlineFriends.sort(sortByName);

    final hasPending = incoming.isNotEmpty || outgoing.isNotEmpty;

    return CustomScrollView(
      slivers: [
        // Search + Add Friend
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.sm,
            ),
            child: Column(
              children: [
                HollowTextField(
                  controller: _searchController,
                  hintText: 'Search friends...',
                  prefixIcon: const Icon(LucideIcons.search, size: 16),
                  isDense: true,
                ),
                const SizedBox(height: HollowSpacing.sm),
                HollowButton.outline(
                  onPressed: () => _showAddFriendDialog(context, ref),
                  icon: const Icon(LucideIcons.userPlus, size: 16),
                  expand: true,
                  child: const Text('Add Friend'),
                ),
              ],
            ),
          ),
        ),

        // Pending requests
        if (hasPending && _searchQuery.isEmpty) ...[
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

        // Favourites
        if (favFriends.isNotEmpty) ...[
          _SectionHeader(label: 'FAVOURITES', count: favFriends.length),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _FriendRow(
                peerId: favFriends[index].peerId,
                isFavourite: true,
              ),
              childCount: favFriends.length,
            ),
          ),
        ],

        // Online
        if (onlineFriends.isNotEmpty) ...[
          _SectionHeader(label: 'ONLINE', count: onlineFriends.length),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _FriendRow(peerId: onlineFriends[index].peerId),
              childCount: onlineFriends.length,
            ),
          ),
        ],

        // Offline
        if (offlineFriends.isNotEmpty) ...[
          _SectionHeader(label: 'OFFLINE', count: offlineFriends.length),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _FriendRow(peerId: offlineFriends[index].peerId),
              childCount: offlineFriends.length,
            ),
          ),
        ],

        // Empty state
        if (accepted.isEmpty && !hasPending)
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
                    Text('Add a friend by their peer ID',
                        style: HollowTypography.bodySmall),
                  ],
                ),
              ),
            ),
          ),

        const SliverPadding(padding: EdgeInsets.only(bottom: HollowSpacing.xl)),
      ],
    );
  }

  String _resolvedName(String peerId) {
    final nicknames = ref.read(localNicknameProvider);
    final profiles = ref.read(profileProvider);
    return nicknames[peerId] ?? displayNameFor(profiles, peerId);
  }

  void _showAddFriendDialog(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => const _AddFriendSheet(),
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
// Friend row with long-press actions
// ─────────────────────────────────────────────────

class _FriendRow extends ConsumerWidget {
  final String peerId;
  final bool isFavourite;

  const _FriendRow({required this.peerId, this.isFavourite = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final localNicknames = ref.watch(localNicknameProvider);
    final isOnline = identityIsOnline(ref, peerId);
    final localNick = localNicknames[peerId];
    final name = localNick ?? displayNameFor(profiles, peerId);

    return HollowPressable(
      onTap: () {
        ref.read(selectedPeerProvider.notifier).state = peerId;
        Navigator.of(context, rootNavigator: true).push(
          hollowMobileRoute(
            builder: (_) => MobileChatRoute(peerId: peerId),
          ),
        ).then((_) {
          ref.read(selectedPeerProvider.notifier).state = null;
        });
      },
      onLongPress: () => _showActions(context, ref),
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
                      filled: isOnline,
                      semanticLabel: isOnline ? 'Online' : 'Offline',
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
                Row(
                  children: [
                    if (isFavourite)
                      Padding(
                        padding: const EdgeInsets.only(right: HollowSpacing.xs),
                        child: Icon(LucideIcons.star, size: 14, color: hollow.warning),
                      ),
                    Flexible(
                      child: Text(name,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textPrimary, fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
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

  void _showActions(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.read(profileProvider);
    final localNicknames = ref.read(localNicknameProvider);
    final favs = ref.read(favouriteFriendsProvider);
    final isFav = favs.contains(peerId);
    final name = localNicknames[peerId] ?? displayNameFor(profiles, peerId);

    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(width: 32, height: 4,
                decoration: BoxDecoration(color: hollow.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(name, style: HollowTypography.body.copyWith(
              color: hollow.textPrimary, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: HollowSpacing.md),
            Divider(height: 1, color: hollow.border),

            _ActionRow(
              icon: LucideIcons.messageCircle,
              label: 'Message',
              onTap: () {
                Navigator.pop(context);
                ref.read(selectedPeerProvider.notifier).state = peerId;
                Navigator.of(context, rootNavigator: true).push(
                  hollowMobileRoute(builder: (_) => MobileChatRoute(peerId: peerId)),
                ).then((_) {
                  ref.read(selectedPeerProvider.notifier).state = null;
                });
              },
            ),

            _ActionRow(
              icon: LucideIcons.user,
              label: 'View Profile',
              onTap: () {
                Navigator.pop(context);
                showMobileProfileSheet(context, peerId: peerId);
              },
            ),

            _ActionRow(
              icon: isFav ? LucideIcons.starOff : LucideIcons.star,
              label: isFav ? 'Unfavourite' : 'Favourite',
              onTap: () {
                Navigator.pop(context);
                ref.read(favouriteFriendsProvider.notifier).toggle(peerId);
              },
            ),

            _ActionRow(
              icon: LucideIcons.tag,
              label: localNicknames[peerId] != null ? 'Edit Nickname' : 'Set Nickname',
              onTap: () {
                Navigator.pop(context);
                _showNicknameDialog(context, ref);
              },
            ),

            Divider(height: 1, color: hollow.border),

            _ActionRow(
              icon: LucideIcons.userMinus,
              label: 'Remove Friend',
              color: hollow.error,
              onTap: () {
                Navigator.pop(context);
                _confirmRemove(context, ref, name);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showNicknameDialog(BuildContext context, WidgetRef ref) {
    final current = ref.read(localNicknameProvider)[peerId] ?? '';
    final controller = TextEditingController(text: current);
    showHollowDialog(
      context: context,
      builder: (_) => HollowDialog(
        title: 'Set Nickname',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Only visible to you.', style: HollowTypography.bodySmall),
            const SizedBox(height: HollowSpacing.lg),
            HollowTextField(
              controller: controller,
              hintText: 'Nickname',
              maxLength: 32,
              showCounter: true,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () {
              final nickname = controller.text.trim();
              ref.read(localNicknameProvider.notifier).setNickname(peerId, nickname);
              Navigator.pop(context);
              HollowToast.show(context,
                  nickname.isEmpty ? 'Nickname cleared' : 'Nickname set',
                  type: HollowToastType.success);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _confirmRemove(BuildContext context, WidgetRef ref, String name) {
    showHollowDialog(
      context: context,
      builder: (_) => HollowDialog(
        title: 'Remove Friend',
        content: Text('Remove $name from your friends?', style: HollowTypography.body),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () {
              Navigator.pop(context);
              ref.read(friendsProvider.notifier).removeFriend(peerId);
              // Also drop them from favourites so no stale entry lingers (parity
              // with desktop). peerId is the master from the collapsed list.
              ref.read(favouriteFriendsProvider.notifier).remove(peerId);
              HollowToast.show(context, 'Friend removed', type: HollowToastType.success);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Action row for bottom sheet
// ─────────────────────────────────────────────────

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final c = color ?? hollow.textPrimary;
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: HollowSpacing.md),
          Text(label, style: HollowTypography.body.copyWith(color: c)),
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
              semanticLabel: 'Accept friend request',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Icon(LucideIcons.check, size: 20, color: hollow.success),
            ),
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: () => ref.read(friendsProvider.notifier).rejectRequest(peerId),
              semanticLabel: 'Decline friend request',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Icon(LucideIcons.x, size: 20, color: hollow.error),
            ),
          ] else
            HollowPressable(
              onTap: () => ref.read(friendsProvider.notifier).rejectRequest(peerId),
              semanticLabel: 'Cancel friend request',
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
// Add Friend bottom sheet
// ─────────────────────────────────────────────────

class _AddFriendSheet extends ConsumerStatefulWidget {
  const _AddFriendSheet();

  @override
  ConsumerState<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<_AddFriendSheet> {
  final _inputController = TextEditingController();
  final _nicknameClaimController = TextEditingController();
  bool _sending = false;

  static bool _isPeerId(String input) => input.startsWith('12D3KooW');

  @override
  void dispose() {
    _inputController.dispose();
    _nicknameClaimController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final input = _inputController.text.trim();
    if (input.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      if (_isPeerId(input)) {
        await ref.read(friendsProvider.notifier).sendRequest(input);
      } else {
        await network_api.sendFriendRequestByNickname(nickname: input);
      }
      if (mounted) {
        Navigator.of(context).pop();
        HollowToast.show(
          context,
          _isPeerId(input) ? 'Friend request sent' : 'Looking up nickname...',
          type: HollowToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to send request',
            type: HollowToastType.error);
        setState(() => _sending = false);
      }
    }
  }

  void _claimNickname() {
    final nickname = _nicknameClaimController.text.trim().toLowerCase();
    if (nickname.isEmpty) return;
    ref.read(temporaryNicknameProvider.notifier).claim(nickname);
    _nicknameClaimController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final nicknameState = ref.watch(temporaryNicknameProvider);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg,
              HollowSpacing.sm,
              HollowSpacing.lg,
              HollowSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: hollow.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: HollowSpacing.lg),
                Text(
                  'Add Friend',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  "Enter your friend's peer ID or temporary nickname.",
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
                const SizedBox(height: HollowSpacing.lg),
                TextField(
                  controller: _inputController,
                  autofocus: true,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Peer ID or nickname...',
                    hintStyle: HollowTypography.mono.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 12,
                    ),
                    filled: true,
                    fillColor: hollow.elevated,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.md,
                      vertical: HollowSpacing.md,
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
                const SizedBox(height: HollowSpacing.md),
                // Primary action sits directly under the input — no
                // competing buttons in between.
                HollowButton.filled(
                  onPressed: _sending ? null : _send,
                  expand: true,
                  icon: const Icon(LucideIcons.userPlus, size: 16),
                  child: Text(_sending ? 'Sending...' : 'Send Friend Request'),
                ),

                const SizedBox(height: HollowSpacing.xl),

                // Secondary: claim a nickname so OTHERS can add YOU.
                // Visually boxed off so it doesn't read as part of the
                // add-friend flow above.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(HollowSpacing.md),
                  decoration: BoxDecoration(
                    color: hollow.elevated.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(hollow.radiusLg),
                    border: Border.all(
                        color: hollow.border.withValues(alpha: 0.6)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(LucideIcons.atSign,
                              size: 14, color: hollow.textSecondary),
                          const SizedBox(width: HollowSpacing.xs),
                          Text(
                            'Want them to add you instead?',
                            style: HollowTypography.bodySmall.copyWith(
                              color: hollow.textPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: HollowSpacing.xs),
                      Text(
                        'Claim a temporary nickname and share it — friends '
                        'can use it instead of your full peer ID. It resets '
                        'when you go offline.',
                        style: HollowTypography.caption
                            .copyWith(color: hollow.textSecondary),
                      ),
                      const SizedBox(height: HollowSpacing.md),
                      if (nicknameState.status == NicknameStatus.claimed)
                        Row(
                          children: [
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: HollowSpacing.md,
                                  vertical: HollowSpacing.sm,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      hollow.accent.withValues(alpha: 0.12),
                                  borderRadius:
                                      BorderRadius.circular(hollow.radiusMd),
                                  border: Border.all(
                                      color: hollow.accent
                                          .withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  nicknameState.nickname ?? '',
                                  style: HollowTypography.mono.copyWith(
                                    color: hollow.accent,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: HollowSpacing.sm),
                            HollowButton.ghost(
                              compact: true,
                              onPressed: () => ref
                                  .read(temporaryNicknameProvider.notifier)
                                  .release(),
                              child: const Text('Release'),
                            ),
                          ],
                        )
                      else
                        Row(
                          children: [
                            Expanded(
                              child: HollowTextField(
                                controller: _nicknameClaimController,
                                hintText: '3-20 chars...',
                                style: HollowTypography.mono.copyWith(
                                  color: hollow.textPrimary,
                                  fontSize: 12,
                                ),
                                onSubmitted: (_) => _claimNickname(),
                              ),
                            ),
                            const SizedBox(width: HollowSpacing.sm),
                            HollowButton.outline(
                              onPressed: nicknameState.status ==
                                      NicknameStatus.claiming
                                  ? null
                                  : _claimNickname,
                              child: Text(
                                nicknameState.status ==
                                        NicknameStatus.claiming
                                    ? 'Claiming...'
                                    : 'Claim',
                              ),
                            ),
                          ],
                        ),
                      if (nicknameState.status == NicknameStatus.failed &&
                          nicknameState.error != null) ...[
                        const SizedBox(height: HollowSpacing.sm),
                        Text(
                          nicknameState.error == 'taken'
                              ? 'That nickname is already taken'
                              : nicknameState.error == 'invalid'
                                  ? 'Nickname must be 3-20 chars: lowercase letters, numbers, underscores'
                                  : 'Failed to claim nickname',
                          style: HollowTypography.caption
                              .copyWith(color: hollow.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

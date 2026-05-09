import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Horizontal friends bar for the Dock layout.
/// Shows accepted friends as avatars with online dots, plus "Add Friend" button.
class FriendsBar extends ConsumerWidget {
  const FriendsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final displayList = ref.watch(sortedFriendsProvider);
    final pendingCount = ref.watch(pendingFriendCountProvider);
    final peers = ref.watch(peersProvider);
    final invisiblePeers = ref.watch(invisiblePeersProvider);
    final profiles = ref.watch(profileProvider);
    final unreadState = ref.watch(unreadProvider);
    final notifSettings = ref.watch(notificationSettingsProvider);
    final selectedPeerId = ref.watch(selectedPeerProvider);

    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 1.0),
        border: Border(
          bottom: BorderSide(color: hollow.border),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: HollowSpacing.sm),

          // Add Friend button
          Stack(
            clipBehavior: Clip.none,
            children: [
              HollowTooltip(
                message: 'Add Friend',
                child: HollowPressable(
                  onTap: () => _showAddFriendDialog(context, ref, hollow),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Icon(
                    LucideIcons.userPlus,
                    size: 18,
                    color: hollow.textSecondary,
                  ),
                ),
              ),
              // Pending badge
              if (pendingCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: hollow.error,
                      shape: BoxShape.circle,
                      border: Border.all(color: hollow.surface, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$pendingCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          // Vertical divider
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
            color: hollow.border,
          ),

          // Friends list (horizontal scroll)
          Expanded(
            child: displayList.isEmpty
                ? Padding(
                    padding: const EdgeInsets.only(left: HollowSpacing.sm),
                    child: Text(
                      'No friends yet',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: displayList.length,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.xs,
                    ),
                    itemBuilder: (context, index) {
                      final friend = displayList[index];
                      final isOnline = peers.containsKey(friend.peerId) &&
                          !invisiblePeers.contains(friend.peerId);
                      final isSelected = friend.peerId == selectedPeerId;
                      final name = displayNameFor(profiles, friend.peerId);

                      // Check unread
                      final unreadCount =
                          notifSettings.isDmEnabled(friend.peerId)
                          ? (unreadState.dmUnreadCounts[friend.peerId] ?? 0)
                          : 0;

                      return _FriendChip(
                        peerId: friend.peerId,
                        name: name,
                        isOnline: isOnline,
                        isSelected: isSelected,
                        unreadCount: unreadCount,
                        onTap: () => _selectFriend(ref, friend.peerId),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _selectFriend(WidgetRef ref, String peerId) {
    final split = ref.read(splitViewProvider);
    if (split.isSplit && split.focusedPane == 1) {
      ref.read(splitViewProvider.notifier).navigateRightToPeer(peerId);
    } else {
      ref.read(archiveTabOpenProvider.notifier).state = false;
      ref.read(shareTabOpenProvider.notifier).state = false;
      ref.read(selectedPeerProvider.notifier).state = peerId;
      ref.read(selectedServerProvider.notifier).state = null;
      ref.read(channelListProvider.notifier).clear();
      ref.read(selectedChannelProvider.notifier).state = null;
      ref.read(serverSettingsOpenProvider.notifier).state = false;
    }
    // Mark as read.
    ref.read(unreadProvider.notifier).markDmSeen(peerId, null);
  }

  void _showAddFriendDialog(
      BuildContext context, WidgetRef ref, HollowTheme hollow) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Friends',
      barrierColor: Colors.black.withValues(alpha: 0.5),
      transitionDuration: HollowDurations.normal,
      pageBuilder: (context, anim1, anim2) {
        return const Center(child: _FriendsManager());
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOut),
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.95, end: 1.0).animate(
              CurvedAnimation(parent: anim1, curve: Curves.easeOut),
            ),
            child: child,
          ),
        );
      },
    );
  }
}

/// Full Friends Manager dialog with tabs.
class _FriendsManager extends ConsumerStatefulWidget {
  const _FriendsManager();

  @override
  ConsumerState<_FriendsManager> createState() => _FriendsManagerState();
}

enum _FriendsTab { friends, favourites, incoming, outgoing, add }

class _FriendsManagerState extends ConsumerState<_FriendsManager> {
  _FriendsTab _activeTab = _FriendsTab.friends;
  final _addController = TextEditingController();

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final friends = ref.watch(friendsProvider);
    final peers = ref.watch(peersProvider);
    final invPeers = ref.watch(invisiblePeersProvider);

    final accepted = friends.values
        .where((f) => f.status == 'accepted')
        .toList()
      ..sort((a, b) {
        final aOn = (peers.containsKey(a.peerId) && !invPeers.contains(a.peerId)) ? 0 : 1;
        final bOn = (peers.containsKey(b.peerId) && !invPeers.contains(b.peerId)) ? 0 : 1;
        if (aOn != bOn) return aOn.compareTo(bOn);
        return a.peerId.compareTo(b.peerId);
      });
    final incoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList();
    final outgoing = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'outgoing')
        .toList();

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 520,
        height: 480,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: hollow.background,
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          border: Border.all(color: hollow.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            // Header with title + close
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg,
              ),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: hollow.border),
                ),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.users, size: 18,
                      color: hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    'Friends',
                    style: HollowTypography.subheading.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  HollowPressable(
                    onTap: () => Navigator.pop(context),
                    borderRadius:
                        BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.x, size: 18,
                        color: hollow.textSecondary),
                  ),
                ],
              ),
            ),

            // Tab bar
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
              ),
              decoration: BoxDecoration(
                color: hollow.surface,
                border: Border(
                  bottom: BorderSide(color: hollow.border),
                ),
              ),
              child: Row(
                children: [
                  _TabButton(
                    label: 'Friends',
                    count: accepted.length,
                    isActive: _activeTab == _FriendsTab.friends,
                    onTap: () => setState(
                        () => _activeTab = _FriendsTab.friends),
                  ),
                  _TabButton(
                    label: 'Favourites',
                    count: ref.watch(favouriteFriendsProvider).length,
                    isActive: _activeTab == _FriendsTab.favourites,
                    icon: LucideIcons.star,
                    onTap: () => setState(
                        () => _activeTab = _FriendsTab.favourites),
                  ),
                  _TabButton(
                    label: 'Incoming',
                    count: incoming.length,
                    isActive: _activeTab == _FriendsTab.incoming,
                    showBadge: incoming.isNotEmpty,
                    onTap: () => setState(
                        () => _activeTab = _FriendsTab.incoming),
                  ),
                  _TabButton(
                    label: 'Outgoing',
                    count: outgoing.length,
                    isActive: _activeTab == _FriendsTab.outgoing,
                    onTap: () => setState(
                        () => _activeTab = _FriendsTab.outgoing),
                  ),
                  _TabButton(
                    label: 'Add Friend',
                    isActive: _activeTab == _FriendsTab.add,
                    icon: LucideIcons.userPlus,
                    onTap: () =>
                        setState(() => _activeTab = _FriendsTab.add),
                  ),
                ],
              ),
            ),

            // Tab content
            Expanded(
              child: AnimatedSwitcher(
                duration: HollowDurations.fast,
                child: switch (_activeTab) {
                  _FriendsTab.friends => _FriendsListTab(
                      key: const ValueKey('friends'),
                      accepted: accepted,
                    ),
                  _FriendsTab.favourites => _FavouritesReorderTab(
                      key: const ValueKey('favourites'),
                      accepted: accepted,
                    ),
                  _FriendsTab.incoming => _RequestsTab(
                      key: const ValueKey('incoming'),
                      requests: incoming,
                      direction: 'incoming',
                    ),
                  _FriendsTab.outgoing => _RequestsTab(
                      key: const ValueKey('outgoing'),
                      requests: outgoing,
                      direction: 'outgoing',
                    ),
                  _FriendsTab.add => _AddFriendTab(
                      key: const ValueKey('add'),
                      controller: _addController,
                    ),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tab button in the Friends Manager header.
class _TabButton extends StatelessWidget {
  final String label;
  final int? count;
  final bool isActive;
  final bool showBadge;
  final IconData? icon;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    this.count,
    required this.isActive,
    this.showBadge = false,
    this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13,
                color: isActive ? hollow.accent : hollow.textSecondary),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: isActive ? hollow.accent : hollow.textSecondary,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              fontSize: 12,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: showBadge
                    ? hollow.error
                    : (isActive ? hollow.accent : hollow.textSecondary)
                        .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: showBadge
                      ? Colors.white
                      : (isActive ? hollow.accent : hollow.textSecondary),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Friends list tab — shows accepted friends with remove button.
class _FriendsListTab extends ConsumerWidget {
  final List<FriendInfo> accepted;
  const _FriendsListTab({super.key, required this.accepted});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final peers = ref.watch(peersProvider);
    final invPeers = ref.watch(invisiblePeersProvider);

    if (accepted.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.users, size: 40,
                color: hollow.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: HollowSpacing.md),
            Text('No friends yet',
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary)),
            const SizedBox(height: HollowSpacing.xs),
            Text('Add a friend by their peer ID',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary)),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: accepted.length,
      padding: const EdgeInsets.all(HollowSpacing.md),
      itemBuilder: (context, index) {
        final friend = accepted[index];
        final name = displayNameFor(profiles, friend.peerId);
        final isOnline = peers.containsKey(friend.peerId) &&
            !invPeers.contains(friend.peerId);

        return Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm + 2,
              vertical: HollowSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    HollowAvatar(peerId: friend.peerId, size: 32),
                    Positioned(
                      right: -1,
                      bottom: -1,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: hollow.elevated,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: StatusDot(
                          color: isOnline
                              ? hollow.success
                              : hollow.textSecondary,
                          size: 7,
                          pulse: isOnline,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isOnline ? 'Online' : 'Offline',
                        style: HollowTypography.caption.copyWith(
                          color: isOnline
                              ? hollow.success
                              : hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Builder(builder: (context) {
                  final isFav = ref.watch(favouriteFriendsProvider)
                      .contains(friend.peerId);
                  return HollowTooltip(
                    message: isFav
                        ? 'Remove from favourites'
                        : 'Add to favourites',
                    child: HollowPressable(
                      onTap: () => ref
                          .read(favouriteFriendsProvider.notifier)
                          .toggle(friend.peerId),
                      borderRadius:
                          BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(
                        isFav ? LucideIcons.star : LucideIcons.star,
                        size: 16,
                        color: isFav
                            ? hollow.warning
                            : hollow.textSecondary.withValues(alpha: 0.4),
                      ),
                    ),
                  );
                }),
                const SizedBox(width: 2),
                HollowTooltip(
                  message: 'Remove friend',
                  child: HollowPressable(
                    onTap: () {
                      final peerId = friend.peerId;
                      ref
                          .read(friendsProvider.notifier)
                          .removeFriend(peerId);
                      // Also remove from favourites.
                      ref
                          .read(favouriteFriendsProvider.notifier)
                          .remove(peerId);
                      // Close chat if viewing this friend.
                      if (ref.read(selectedPeerProvider) == peerId) {
                        ref.read(selectedPeerProvider.notifier).state =
                            null;
                      }
                      // Close split pane if it shows this friend.
                      final split = ref.read(splitViewProvider);
                      if (split.isSplit &&
                          split.rightPane?.peerId == peerId) {
                        ref
                            .read(splitViewProvider.notifier)
                            .closeSplit();
                      }
                    },
                    borderRadius:
                        BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.userMinus, size: 16,
                        color: hollow.error),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Favourites reorder tab — drag to reposition favourite friends.
class _FavouritesReorderTab extends ConsumerWidget {
  final List<FriendInfo> accepted;
  const _FavouritesReorderTab({super.key, required this.accepted});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final favourites = ref.watch(favouriteFriendsProvider);
    final profiles = ref.watch(profileProvider);
    final peers = ref.watch(peersProvider);
    final invPeers = ref.watch(invisiblePeersProvider);
    final acceptedIds = accepted.map((f) => f.peerId).toSet();

    // Filter to valid favourites only.
    final validFavs = favourites.where((id) => acceptedIds.contains(id)).toList();

    if (validFavs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.star, size: 40,
                color: hollow.textSecondary.withValues(alpha: 0.3)),
            const SizedBox(height: HollowSpacing.md),
            Text('No favourites yet',
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary)),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              'Star a friend in the Friends tab to add them here',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary),
            ),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.all(HollowSpacing.md),
      itemCount: validFavs.length,
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (ctx, child) => Material(
            color: Colors.transparent,
            elevation: 4,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            child: child,
          ),
          child: child,
        );
      },
      onReorder: (oldIndex, newIndex) {
        ref.read(favouriteFriendsProvider.notifier).reorder(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final peerId = validFavs[index];
        final name = displayNameFor(profiles, peerId);
        final isOnline = peers.containsKey(peerId) &&
            !invPeers.contains(peerId);

        return Padding(
          key: ValueKey(peerId),
          padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm + 2,
              vertical: HollowSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Icon(LucideIcons.gripVertical,
                      size: 16, color: hollow.textSecondary),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowAvatar(
                  peerId: peerId,
                  size: 28,
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isOnline ? 'Online' : 'Offline',
                        style: HollowTypography.caption.copyWith(
                          color: isOnline
                              ? hollow.success
                              : hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                HollowTooltip(
                  message: 'Remove from favourites',
                  child: HollowPressable(
                    onTap: () => ref
                        .read(favouriteFriendsProvider.notifier)
                        .remove(peerId),
                    borderRadius:
                        BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.x, size: 14,
                        color: hollow.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Incoming/Outgoing requests tab.
class _RequestsTab extends ConsumerStatefulWidget {
  final List<FriendInfo> requests;
  final String direction;
  const _RequestsTab({
    super.key,
    required this.requests,
    required this.direction,
  });

  @override
  ConsumerState<_RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends ConsumerState<_RequestsTab> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);

    if (widget.requests.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.direction == 'incoming'
                  ? LucideIcons.inbox
                  : LucideIcons.send,
              size: 40,
              color: hollow.textSecondary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              widget.direction == 'incoming'
                  ? 'No incoming requests'
                  : 'No outgoing requests',
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
            ),
          ],
        ),
      );
    }

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.requests
        : widget.requests.where((r) {
            final name = displayNameFor(profiles, r.peerId).toLowerCase();
            return name.contains(q) || r.peerId.toLowerCase().contains(q);
          }).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.md,
            HollowSpacing.md,
            HollowSpacing.md,
            HollowSpacing.sm,
          ),
          child: HollowTextField(
            controller: _searchController,
            hintText: widget.direction == 'incoming'
                ? 'Search incoming requests...'
                : 'Search outgoing requests...',
            prefixIcon: Icon(
              LucideIcons.search,
              size: 16,
              color: hollow.textSecondary,
            ),
            isDense: true,
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    'No matches',
                    style: HollowTypography.body
                        .copyWith(color: hollow.textSecondary),
                  ),
                )
              : _buildList(hollow, profiles, filtered),
        ),
      ],
    );
  }

  Widget _buildList(
    HollowTheme hollow,
    Map<String, storage_api.UserProfile> profiles,
    List<FriendInfo> requests,
  ) {
    return ListView.builder(
      itemCount: requests.length,
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.md,
        0,
        HollowSpacing.md,
        HollowSpacing.md,
      ),
      itemBuilder: (context, index) {
        final req = requests[index];
        final name = displayNameFor(profiles, req.peerId);
        final direction = widget.direction;

        return Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm + 2,
              vertical: HollowSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            child: Row(
              children: [
                HollowAvatar(peerId: req.peerId, size: 32),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        direction == 'incoming'
                            ? 'Wants to be friends'
                            : 'Request sent',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                if (direction == 'incoming') ...[
                  HollowTooltip(
                    message: 'Accept',
                    child: HollowPressable(
                      onTap: () => ref
                          .read(friendsProvider.notifier)
                          .acceptRequest(req.peerId),
                      borderRadius:
                          BorderRadius.circular(hollow.radiusSm),
                      padding:
                          const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(LucideIcons.check,
                          size: 16, color: hollow.success),
                    ),
                  ),
                  HollowTooltip(
                    message: 'Reject',
                    child: HollowPressable(
                      onTap: () => ref
                          .read(friendsProvider.notifier)
                          .rejectRequest(req.peerId),
                      borderRadius:
                          BorderRadius.circular(hollow.radiusSm),
                      padding:
                          const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(LucideIcons.x,
                          size: 16, color: hollow.error),
                    ),
                  ),
                ] else
                  HollowTooltip(
                    message: 'Cancel request',
                    child: HollowPressable(
                      onTap: () => ref
                          .read(friendsProvider.notifier)
                          .rejectRequest(req.peerId),
                      borderRadius:
                          BorderRadius.circular(hollow.radiusSm),
                      padding:
                          const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(LucideIcons.x,
                          size: 16, color: hollow.error),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Add Friend tab — peer ID input.
class _AddFriendTab extends ConsumerWidget {
  final TextEditingController controller;
  const _AddFriendTab({super.key, required this.controller});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add a friend by their peer ID',
            style: HollowTypography.body
                .copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Expanded(
                child: HollowTextField(
                  controller: controller,
                  hintText: 'Paste peer ID...',
                  autofocus: true,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                  ),
                  onSubmitted: (_) => _send(context, ref),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                onPressed: () => _send(context, ref),
                child: const Text('Send Request'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _send(BuildContext context, WidgetRef ref) {
    final peerId = controller.text.trim();
    if (peerId.isEmpty) return;
    ref.read(friendsProvider.notifier).sendRequest(peerId);
    controller.clear();
    HollowToast.show(
      context,
      'Friend request sent',
      type: HollowToastType.success,
    );
  }
}

/// Single friend chip in the horizontal bar.
class _FriendChip extends StatelessWidget {
  final String peerId;
  final String name;
  final bool isOnline;
  final bool isSelected;
  final int unreadCount;
  final VoidCallback onTap;

  const _FriendChip({
    required this.peerId,
    required this.name,
    required this.isOnline,
    required this.isSelected,
    required this.unreadCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: HollowTooltip(
        message: name,
        child: HollowPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          hoverColor: hollow.elevated,
          backgroundColor:
              isSelected ? hollow.accent.withValues(alpha: 0.15) : null,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: 4,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Avatar with status dot
              Stack(
                clipBehavior: Clip.none,
                children: [
                  HollowAvatar(peerId: peerId, size: 24),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: hollow.surface,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: StatusDot(
                        color: isOnline ? hollow.success : hollow.textSecondary,
                        size: 7,
                        pulse: isOnline,
                      ),
                    ),
                  ),
                  // Unread indicator
                  if (unreadCount > 0)
                    Positioned(
                      left: -4,
                      top: -4,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 16),
                        height: 16,
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: hollow.error,
                          borderRadius: BorderRadius.circular(8),
                          border:
                              Border.all(color: hollow.surface, width: 1.5),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          unreadCount > 99 ? '99+' : '$unreadCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 6),
              // Name
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 72),
                child: Text(
                  name,
                  style: HollowTypography.caption.copyWith(
                    color: isSelected
                        ? hollow.textPrimary
                        : hollow.textSecondary,
                    fontWeight:
                        unreadCount > 0 ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

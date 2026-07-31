import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/temporary_nickname_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/core/providers/help_panel_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Horizontal friends bar for the Dock layout.
/// Shows accepted friends as avatars with online dots, plus "Add Friend" button.
class FriendsBar extends ConsumerWidget {
  const FriendsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // The DOCK shows favourites-only when favourites are set (its purpose), via
    // the dedicated display provider. The Friends dialog/home/chats use the
    // unfiltered sortedFriendsProvider so favouriting never hides a friend there.
    final displayList = ref.watch(friendsBarDisplayProvider);
    final pendingCount = ref.watch(pendingFriendCountProvider);
    final online = ref.watch(onlineIdentitiesProvider);
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
      // a11y Phase 3: fixed-height (44px) friends-bar chrome — cap label scale
      // across the whole strip (chip names, counts, empty state) so it stays in
      // the bar at high OS text size. Content areas honor full 2.0×.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
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
                  semanticLabel: 'Add friend',
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
                // .builder, not the children: form — this list is LAZY and a
                // long friends list must stay that way. Arrows + wheel appear
                // only while it overflows; before this, friends past the edge
                // were unreachable on a plain wheel mouse.
                : EdgeScrollRow.builder(
                    semanticLabel: 'friends',
                    builder: (context, scrollController) =>
                        ListView.builder(
                    controller: scrollController,
                    scrollDirection: Axis.horizontal,
                    itemCount: displayList.length,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.xs,
                    ),
                    itemBuilder: (context, index) {
                      final friend = displayList[index];
                      final isOnline = online.contains(friend.peerId);
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
                  )),
          ),

          // Vertical divider (mirrors the left side for symmetry)
          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
            color: hollow.border,
          ),

          // Saved messages button — opens the DM with your own master identity.
          Builder(builder: (context) {
            final savedId = ref.watch(savedMessagesPeerIdProvider);
            final isActive = savedId != null && savedId == selectedPeerId;
            return HollowTooltip(
              message: 'Saved messages',
              child: HollowPressable(
                semanticLabel: 'Saved messages',
                // Toggles, like Conferences beside it: pressing the lit
                // button again puts the centre pane back to Home. Every
                // other button on this strip that lights up also unlights,
                // so the one that didn't read as a dead press.
                onTap: savedId == null
                    ? null
                    : () => _toggleSavedMessages(ref, savedId),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: HollowSpacing.xs,
                ),
                child: Icon(
                  LucideIcons.bookmark,
                  size: 18,
                  color: isActive ? hollow.accent : hollow.textSecondary,
                ),
              ),
            );
          }),
          const SizedBox(width: HollowSpacing.xs),

          // Conferences button — opens the Conferences center tab.
          Builder(builder: (context) {
            final conferencesOpen = ref.watch(conferenceTabOpenProvider);
            return HollowTooltip(
              message: 'Conferences',
              child: HollowPressable(
                semanticLabel: 'Conferences',
                // Toggles: pressing the lit button again is how you get back
                // to what you were doing (issue #28).
                onTap: () => conferencesOpen
                    ? setShellTab(ref.read, null)
                    : ref.read(conferenceProvider.notifier).openTab(),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: HollowSpacing.xs,
                ),
                child: Icon(
                  LucideIcons.video,
                  size: 18,
                  color: conferencesOpen
                      ? hollow.accent
                      : hollow.textSecondary,
                ),
              ),
            );
          }),
          const SizedBox(width: HollowSpacing.xs),

          // Help button (right side — symmetric with Add Friend on the left)
          Builder(builder: (context) {
            final helpOpen = ref.watch(helpPanelOpenProvider);
            return HollowTooltip(
              message: 'Help',
              child: HollowPressable(
                semanticLabel: 'Help',
                onTap: () => ref
                    .read(helpPanelOpenProvider.notifier)
                    .state = !helpOpen,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.sm,
                  vertical: HollowSpacing.xs,
                ),
                child: Icon(
                  LucideIcons.circleHelp,
                  size: 18,
                  color: helpOpen ? hollow.accent : hollow.textSecondary,
                ),
              ),
            );
          }),
          const SizedBox(width: HollowSpacing.sm),
        ],
      ),
      ),
    );
  }

  /// Saved messages behaves like the Conferences button next to it: press to
  /// show, press again to put it away.
  ///
  /// The two need different machinery for the same feel. Conferences is a
  /// centre TAB layered over whatever is selected, so closing it is one
  /// `setShellTab(null)` and the selection underneath re-appears. Saved
  /// messages IS the selection — opening it replaces what was there — so
  /// there is nothing underneath to reveal and "away" means Home.
  void _toggleSavedMessages(WidgetRef ref, String savedId) {
    final split = ref.read(splitViewProvider);
    // In split view the right pane is its own context: the button targets
    // that pane rather than the global selection, so there is no global
    // "lit" state to toggle off. Same branch `_selectFriend` takes.
    if (split.isSplit && split.focusedPane == 1) {
      _selectFriend(ref, savedId);
      return;
    }
    if (ref.read(selectedPeerProvider) == savedId) {
      _clearToHome(ref);
      return;
    }
    _selectFriend(ref, savedId);
  }

  /// The exact inverse of [_selectFriend]'s non-split branch — same providers,
  /// peer cleared instead of set. Deliberately does NOT close an open split:
  /// the press that lit this button didn't open one, so putting it away
  /// shouldn't tear one down.
  void _clearToHome(WidgetRef ref) {
    setShellTab(ref.read, null);
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    ref.read(selectedChannelProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
  }

  void _selectFriend(WidgetRef ref, String peerId) {
    final split = ref.read(splitViewProvider);
    if (split.isSplit && split.focusedPane == 1) {
      ref.read(splitViewProvider.notifier).navigateRightToPeer(peerId);
    } else {
      setShellTab(ref.read, null);
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
        // Padding, not just Center: the interface zoom shrinks the logical
        // viewport (`window / scale`), so at 200% on 1080p this 520x480 popup
        // is laid out inside ~960x504. Flutter's constraint enforcement stops
        // it overflowing, but without a margin it clamps flush to the window
        // edges and loses the rounded border that tells you it's a popup.
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(HollowSpacing.lg),
            child: _FriendsManager(),
          ),
        );
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

    // Accepted list is master-collapsed + deduped + sorted by the shared provider
    // (so a friend stranded under a device id by a nickname-add resolves to the
    // right person here too). Pending requests stay raw — the device→master
    // mapping usually isn't known until after acceptance (the re-key then moves
    // the row to the master).
    final accepted = ref.watch(sortedFriendsProvider);
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
                    semanticLabel: 'Close',
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
              // Five labelled tabs with counts and badges — a bare Row
              // overflows at a larger-text setting and clips "Add Friend"
              // out of reach.
              child: EdgeScrollRow(
                semanticLabel: 'tabs',
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
    final online = ref.watch(onlineIdentitiesProvider);

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
        final isOnline = online.contains(friend.peerId);

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
                          filled: isOnline,
                          semanticLabel: isOnline ? 'Online' : 'Offline',
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
                      semanticLabel: isFav
                          ? 'Remove from favourites'
                          : 'Add to favourites',
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
                    semanticLabel: 'Remove friend',
                    onTap: () async {
                      final peerId = friend.peerId;
                      // Capture notifiers/state up front — the awaited
                      // removal rebuilds the friends list and may unmount
                      // this row before the cleanup below runs.
                      final favourites =
                          ref.read(favouriteFriendsProvider.notifier);
                      final selectedPeer =
                          ref.read(selectedPeerProvider.notifier);
                      final wasSelected =
                          ref.read(selectedPeerProvider) == peerId;
                      final splitView =
                          ref.read(splitViewProvider.notifier);
                      final split = ref.read(splitViewProvider);
                      final shownInSplit = split.isSplit &&
                          split.rightPane?.peerId == peerId;
                      try {
                        await ref
                            .read(friendsProvider.notifier)
                            .removeFriend(peerId);
                      } catch (_) {
                        if (context.mounted) {
                          HollowToast.show(
                              context, 'Could not remove friend',
                              type: HollowToastType.error);
                        }
                        return;
                      }
                      // Also remove from favourites.
                      favourites.remove(peerId);
                      // Close chat if viewing this friend.
                      if (wasSelected) selectedPeer.state = null;
                      // Close split pane if it shows this friend.
                      if (shownInSplit) splitView.closeSplit();
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
    final online = ref.watch(onlineIdentitiesProvider);
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
      onReorderItem: (oldIndex, newIndex) {
        ref.read(favouriteFriendsProvider.notifier).reorder(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final peerId = validFavs[index];
        final name = displayNameFor(profiles, peerId);
        final isOnline = online.contains(peerId);

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
                    semanticLabel: 'Remove from favourites',
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
            final id = ref.read(deviceLinkProvider).identityOf(r.peerId);
            final name = displayNameFor(profiles, id).toLowerCase();
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

  /// Await a friend-request mutation and surface failure — the notifier
  /// rethrows (e.g. node not running), and a silent drop here left the row
  /// stuck with no feedback.
  Future<void> _requestAction(
      Future<void> Function() action, String failMsg) async {
    try {
      await action();
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, failMsg, type: HollowToastType.error);
      }
    }
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
        // Resolve the stored id → master for DISPLAY (name + avatar key on the
        // master). A pending request added by nickname can be keyed under a device
        // id until the backend re-key lands; resolving here heals the name/avatar
        // immediately. Accept/reject still target `req.peerId` (the device that sent
        // it / a reachable id), so only the display is resolved.
        final displayId = ref.watch(deviceLinkProvider).identityOf(req.peerId);
        final name = displayNameFor(profiles, displayId);
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
                HollowAvatar(peerId: displayId, size: 32),
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
                      semanticLabel: 'Accept friend request',
                      onTap: () => _requestAction(
                          () => ref
                              .read(friendsProvider.notifier)
                              .acceptRequest(req.peerId),
                          'Could not accept request'),
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
                      semanticLabel: 'Reject friend request',
                      onTap: () => _requestAction(
                          () => ref
                              .read(friendsProvider.notifier)
                              .rejectRequest(req.peerId),
                          'Could not decline request'),
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
                      semanticLabel: 'Cancel friend request',
                      onTap: () => _requestAction(
                          () => ref
                              .read(friendsProvider.notifier)
                              .rejectRequest(req.peerId),
                          'Could not cancel request'),
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

/// Add Friend tab — unified input: auto-detects peer ID vs nickname.
class _AddFriendTab extends ConsumerStatefulWidget {
  final TextEditingController controller;
  const _AddFriendTab({super.key, required this.controller});

  @override
  ConsumerState<_AddFriendTab> createState() => _AddFriendTabState();
}

class _AddFriendTabState extends ConsumerState<_AddFriendTab> {
  final _nicknameClaimController = TextEditingController();

  static bool _isPeerId(String input) => input.startsWith('12D3KooW');

  @override
  void dispose() {
    _nicknameClaimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final nicknameState = ref.watch(temporaryNicknameProvider);

    return Padding(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter a peer ID or temporary nickname',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Expanded(
                child: HollowTextField(
                  controller: widget.controller,
                  hintText: 'Peer ID or nickname...',
                  autofocus: true,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                onPressed: _send,
                child: const Text('Send Request'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xl),
          // -- Your temporary nickname section --
          Divider(color: hollow.border, height: 1),
          const SizedBox(height: HollowSpacing.lg),
          Text(
            'Your temporary nickname',
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Lets others add you without your full peer ID. '
            'Resets when you go offline.',
            style: HollowTypography.caption
                .copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          if (nicknameState.status == NicknameStatus.claimed)
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    border: Border.all(
                        color: hollow.accent.withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    nicknameState.nickname ?? '',
                    style: HollowTypography.mono.copyWith(
                      color: hollow.accent,
                      fontSize: 14,
                    ),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.ghost(
                  compact: true,
                  onPressed: () =>
                      ref.read(temporaryNicknameProvider.notifier).release(),
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
                    hintText: 'Choose a nickname (3-20 chars)...',
                    style: HollowTypography.mono.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 12,
                    ),
                    onSubmitted: (_) => _claimNickname(),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.filled(
                  onPressed:
                      nicknameState.status == NicknameStatus.claiming
                          ? null
                          : _claimNickname,
                  child: Text(
                    nicknameState.status == NicknameStatus.claiming
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
    );
  }

  Future<void> _send() async {
    final input = widget.controller.text.trim();
    if (input.isEmpty) return;
    // Await the send so a failure (e.g. node not running) surfaces here —
    // the input is kept for a retry instead of toasting a false success.
    try {
      if (_isPeerId(input)) {
        await ref.read(friendsProvider.notifier).sendRequest(input);
      } else {
        await network_api.sendFriendRequestByNickname(nickname: input);
      }
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not send request',
            type: HollowToastType.error);
      }
      return;
    }
    if (!mounted) return;
    widget.controller.clear();
    HollowToast.show(
      context,
      _isPeerId(input) ? 'Friend request sent' : 'Looking up nickname...',
      type: HollowToastType.success,
    );
  }

  void _claimNickname() {
    final nickname = _nicknameClaimController.text.trim().toLowerCase();
    if (nickname.isEmpty) return;
    ref.read(temporaryNicknameProvider.notifier).claim(nickname);
    _nicknameClaimController.clear();
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
                        filled: isOnline,
                        semanticLabel: isOnline ? 'Online' : 'Offline',
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
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
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/core/providers/help_panel_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Horizontal friends bar for the Dock layout.
class FriendsBar extends ConsumerWidget {
  const FriendsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // The DOCK shows favourites only once any are set, which is its purpose.
    // Every other surface uses the unfiltered list, so favouriting never hides
    // a friend there.
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
      // Fixed-height chrome, so the label scale is capped across the strip to
      // keep it in the bar at high OS text size. Content areas honour the full
      // range.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Row(
        children: [
          const SizedBox(width: HollowSpacing.sm),

          Stack(
            clipBehavior: Clip.none,
            children: [
              HollowTooltip(
                message: 'Add Friend',
                child: HollowPressable(
                  semanticLabel: 'Add friend',
                  onTap: () => _showAddFriendDialog(context, ref, hollow),
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
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
              if (pendingCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 14),
                    height: 14,
                    padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.xxs),
                    decoration: BoxDecoration(
                      color: hollow.error,
                      borderRadius: BorderRadius.circular(HollowRadius.pill),
                      border: Border.all(color: hollow.surface, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$pendingCount',
                      style: HollowTypography.micro.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        height: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),

          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
            color: hollow.border,
          ),

          Expanded(
            child: displayList.isEmpty
                ? const Padding(
                    padding: EdgeInsets.only(left: HollowSpacing.sm),
                    child: HollowEmptyState(title: 'No friends yet', dense: true),
                  )
                // .builder, not the children: form, so a long friends list
                // stays LAZY. Arrows and wheel appear only while it overflows,
                // or friends past the edge are unreachable on a wheel mouse.
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

          Container(
            width: 1,
            height: 24,
            margin: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
            color: hollow.border,
          ),

          // Absent entirely, not disabled, on store builds: Apple 3.1.1 and
          // Play policy want no shop surface at all.
          if (ref.watch(shopAvailableProvider)) ...[
            Builder(builder: (context) {
              final shopOpen = ref.watch(shopTabOpenProvider);
              return HollowTooltip(
                message: 'Hollow Shop',
                child: HollowPressable(
                  semanticLabel: 'Hollow Shop',
                  // Toggles like every other lit button on this strip
                  // (issue #28).
                  onTap: () => shopOpen
                      ? setShellTab(ref.read, null)
                      : openShopTab(ref.read),
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Icon(
                    LucideIcons.store,
                    size: 18,
                    color: shopOpen ? hollow.accent : hollow.textSecondary,
                  ),
                ),
              );
            }),
            const SizedBox(width: HollowSpacing.xs),
          ],

          // Saved messages is the DM with your own master identity.
          Builder(builder: (context) {
            final savedId = ref.watch(savedMessagesPeerIdProvider);
            final isActive = savedId != null && savedId == selectedPeerId;
            return HollowTooltip(
              message: 'Saved messages',
              child: HollowPressable(
                semanticLabel: 'Saved messages',
                // Toggles, like Conferences beside it. Every other button on
                // this strip that lights up also unlights, so one that does not
                // reads as a dead press.
                onTap: savedId == null
                    ? null
                    : () => _toggleSavedMessages(ref, savedId),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
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

          Builder(builder: (context) {
            final conferencesOpen = ref.watch(conferenceTabOpenProvider);
            return HollowTooltip(
              message: 'Conferences',
              child: HollowPressable(
                semanticLabel: 'Conferences',
                // Toggles: the lit button is how you get back to what you were
                // doing (issue #28).
                onTap: () => conferencesOpen
                    ? setShellTab(ref.read, null)
                    : ref.read(conferenceProvider.notifier).openTab(),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
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

          Builder(builder: (context) {
            final helpOpen = ref.watch(helpPanelOpenProvider);
            return HollowTooltip(
              message: 'Help',
              child: HollowPressable(
                semanticLabel: 'Help',
                onTap: () => ref
                    .read(helpPanelOpenProvider.notifier)
                    .state = !helpOpen,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
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

  /// Press to show, press again to put away, like the Conferences button.
  ///
  /// The two need different machinery for the same feel: Conferences is a
  /// centre tab layered over the selection, while Saved messages IS the
  /// selection, so there is nothing underneath to reveal and "away" means Home.
  void _toggleSavedMessages(WidgetRef ref, String savedId) {
    final split = ref.read(splitViewProvider);
    // In split view the button targets the right pane rather than the global
    // selection, so there is no global "lit" state to toggle off.
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

  /// The exact inverse of [_selectFriend]'s non-split branch. Deliberately does
  /// NOT close an open split: the press that lit this button did not open one.
  void _clearToHome(WidgetRef ref) {
    setShellTab(ref.read, null);
    ref.read(selectedPeerProvider.notifier).state = null;
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    ref.read(selectedChannelProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
  }

  void _selectFriend(WidgetRef ref, String peerId) {
    openDmConversation(ref, peerId);
  }

  void _showAddFriendDialog(
      BuildContext context, WidgetRef ref, HollowTheme hollow) {
    showFriendsManager(context);
  }
}

/// The Friends Manager dialog; [addFriend] opens it on the Add Friend tab.
void showFriendsManager(BuildContext context, {bool addFriend = false}) {
  showHollowDialog(
    context: context,
    builder: (context) => _FriendsManager(addFriend: addFriend),
  );
}

/// Full Friends Manager dialog with tabs.
class _FriendsManager extends ConsumerStatefulWidget {
  final bool addFriend;
  const _FriendsManager({this.addFriend = false});

  @override
  ConsumerState<_FriendsManager> createState() => _FriendsManagerState();
}

enum _FriendsTab { friends, favourites, incoming, outgoing, add }

class _FriendsManagerState extends ConsumerState<_FriendsManager> {
  late _FriendsTab _activeTab =
      widget.addFriend ? _FriendsTab.add : _FriendsTab.friends;
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

    // The accepted list is master-collapsed and deduped by the shared provider.
    // Pending requests stay raw, because the device to master mapping is not
    // usually known until after acceptance.
    final accepted = ref.watch(sortedFriendsProvider);
    final incoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList();
    final outgoing = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'outgoing')
        .toList();

    return HollowDialogSurface(
      width: 520,
      padded: false,
      child: SizedBox(
        height: 480,
        child: Column(
          children: [
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
                  Expanded(
                    child: Text(
                      'Friends',
                      style: HollowTypography.heading.copyWith(
                        color: hollow.textPrimary,
                      ),
                    ),
                  ),
                  const HollowDialogCloseButton(),
                ],
              ),
            ),

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
              // A bare Row overflows at a larger-text setting and clips the
              // last tab out of reach.
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

            // Switching tabs is instant.
            Expanded(
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
      borderRadius: BorderRadius.circular(hollow.radiusMd),
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

/// Friends list tab.
class _FriendsListTab extends ConsumerWidget {
  final List<FriendInfo> accepted;
  const _FriendsListTab({super.key, required this.accepted});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final online = ref.watch(onlineIdentitiesProvider);

    if (accepted.isEmpty) {
      return const HollowEmptyState(
        glyph: LucideIcons.users,
        title: 'No friends yet',
        description: 'Add a friend by their peer ID.',
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
                          BorderRadius.circular(hollow.radiusMd),
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
                    onTap: () =>
                        removeFriendAndTidy(context, ref, friend.peerId),
                    borderRadius:
                        BorderRadius.circular(hollow.radiusMd),
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

/// Favourites reorder tab.
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

    final validFavs = favourites.where((id) => acceptedIds.contains(id)).toList();

    if (validFavs.isEmpty) {
      return const HollowEmptyState(
        glyph: LucideIcons.star,
        title: 'No favourites yet',
        description: 'Star a friend in the Friends tab to add them here.',
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
                        BorderRadius.circular(hollow.radiusMd),
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
      return HollowEmptyState(
        glyph: widget.direction == 'incoming'
            ? LucideIcons.inbox
            : LucideIcons.send,
        title: widget.direction == 'incoming'
            ? 'No incoming requests'
            : 'No outgoing requests',
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
              ? const HollowEmptyState(title: 'No matches')
              : _buildList(hollow, profiles, filtered),
        ),
      ],
    );
  }

  /// Awaits a friend-request mutation and surfaces failure: the notifier
  /// rethrows, and a silent drop leaves the row stuck with no feedback.
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
        // DISPLAY only: a request added by nickname can be keyed under a device
        // id until the re-key lands, and resolving heals the name and avatar.
        // Accept and reject still target `req.peerId`, which is reachable.
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
                      // An outgoing request is not lost while the other person
                      // is offline: it waits in their mailbox and lands on their
                      // next boot, even if the sender has gone offline since.
                      if (direction == 'outgoing')
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            "They'll get this the next time they're online, "
                            "even if you've gone offline by then.",
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 10,
                              height: 1.3,
                            ),
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
                          BorderRadius.circular(hollow.radiusMd),
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
                          BorderRadius.circular(hollow.radiusMd),
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
                          BorderRadius.circular(hollow.radiusMd),
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

/// Add Friend tab, taking either a peer id or a nickname.
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
          const HollowDivider(),
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
                HollowButton.outline(
                  onPressed: _claimNickname,
                  loading: nicknameState.status == NicknameStatus.claiming,
                  child: const Text('Claim'),
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
    // Awaited so a failure surfaces here and the input is kept for a retry,
    // instead of toasting a false success.
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
class _FriendChip extends StatelessWidget { // design-ignore: an avatar tab in the friends bar, not a label
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
      // The same conversation menu the sidebar DM tile has (issue #61). A
      // Consumer rather than a ref field, because passing a WidgetRef into a
      // constructor cascades rebuilds.
      child: Consumer(
        builder: (context, ref, child) => ContextMenuTarget(
          semanticLabel: 'Conversation actions',
          onOpen: (anchor) => showUserContextMenu(
            context: context,
            ref: ref,
            peerId: peerId,
            surface: UserMenuSurface.dmTile,
            anchor: anchor,
          ),
          child: child!,
        ),
        child: HollowTooltip(
        message: name,
        child: HollowPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
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
                        filled: isOnline,
                        semanticLabel: isOnline ? 'Online' : 'Offline',
                      ),
                    ),
                  ),
                  if (unreadCount > 0)
                    Positioned(
                      left: -4,
                      top: -4,
                      child: HollowCountBadge(
                        count: unreadCount,
                        ring: hollow.surface,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 6),
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
      ),
    );
  }
}

/// Removes a friend and closes whatever still shows them: the favourite, the
/// open DM, the split pane. Toasts on failure.
Future<void> removeFriendAndTidy(
    BuildContext context, WidgetRef ref, String peerId) async {
  // Captured up front: the awaited removal rebuilds the friends list and may
  // unmount the caller before the cleanup below runs.
  final favourites = ref.read(favouriteFriendsProvider.notifier);
  final selectedPeer = ref.read(selectedPeerProvider.notifier);
  final wasSelected = ref.read(selectedPeerProvider) == peerId;
  final splitView = ref.read(splitViewProvider.notifier);
  final split = ref.read(splitViewProvider);
  final shownInSplit = split.isSplit && split.rightPane?.peerId == peerId;
  try {
    await ref.read(friendsProvider.notifier).removeFriend(peerId);
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, 'Could not remove friend',
          type: HollowToastType.error);
    }
    return;
  }
  favourites.remove(peerId);
  if (wasSelected) selectedPeer.state = null;
  if (shownInSplit) splitView.closeSplit();
}

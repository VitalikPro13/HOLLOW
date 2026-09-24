import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:hollow/src/ui/dialogs/friends_manager_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

export 'package:hollow/src/ui/dialogs/friends_manager_dialog.dart'
    show FriendsManagerTab, showFriendsManager;

/// The Dock layout's header: your people on the left, and in Dock mode the
/// window's own strip, its empty middle moving the window and its trailing
/// end kept clear for the floating window controls.
class FriendsBar extends ConsumerWidget {
  const FriendsBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final content = ref.watch(friendsBarProvider);
    final pendingCount = ref.watch(pendingFriendCountProvider);

    // In window pixels, so divided by the zoom this strip is drawn at.
    final ownsChrome = ref.watch(dockOwnsWindowChromeProvider);
    final scale = UiScaleInfo.maybeOf(context)?.effective ?? 1.0;
    final controlsWidth =
        ownsChrome ? ref.watch(windowControlsWidthProvider) / scale : 0.0;

    return Container(
      height: kDockHeaderHeight,
      decoration: BoxDecoration(
        color: hollow.opaqueSurface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      // Fixed-height chrome, so the label scale is capped across the strip to
      // keep it in the bar at high OS text size. Content areas honour the full
      // range.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Row(
          children: [
            // The traffic lights sit in the header's leading end on macOS.
            if (ownsChrome && Platform.isMacOS)
              SizedBox(width: kMacTrafficLightGap / scale)
            else
              const SizedBox(width: HollowSpacing.md),
            _AddFriendButton(pendingCount: pendingCount),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: LayoutBuilder(builder: (context, constraints) {
                // The middle never shrinks below this, so the window can
                // always be dragged however many friends there are.
                final chipsMax = (constraints.maxWidth - _kMinDragWidth)
                    .clamp(0.0, double.infinity);
                return Row(
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: chipsMax),
                      child: content.isEmpty
                          ? const _NoFriendsYet()
                          : _FriendStrip(content: content),
                    ),
                    Expanded(
                      child: ownsChrome
                          // Double click maximises too: DragToMoveArea's own.
                          ? const DragToMoveArea(child: SizedBox.expand())
                          : const SizedBox.shrink(),
                    ),
                  ],
                );
              }),
            ),
            SizedBox(width: ownsChrome ? controlsWidth : HollowSpacing.sm),
          ],
        ),
      ),
    );
  }
}

const double _kMinDragWidth = 48;

class _AddFriendButton extends StatelessWidget {
  final int pendingCount;
  const _AddFriendButton({required this.pendingCount});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        HollowIconButton(
          icon: LucideIcons.userPlus,
          label: 'Add friend',
          // With requests waiting, the badge is what the press is for.
          onPressed: () => showFriendsManager(
            context,
            tab: pendingCount > 0
                ? FriendsManagerTab.requests
                : FriendsManagerTab.add,
          ),
        ),
        if (pendingCount > 0)
          Positioned(
            right: -HollowSpacing.xs,
            top: -HollowSpacing.xxs,
            child: IgnorePointer(
              // A request is not a mention: the accent kind, never red.
              child: Semantics(
                label: pendingCount == 1
                    ? '1 friend request'
                    : '$pendingCount friend requests',
                child: ExcludeSemantics(
                  child: HollowCountBadge(
                    count: pendingCount,
                    ring: hollow.opaqueSurface,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _NoFriendsYet extends StatelessWidget {
  const _NoFriendsYet();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            'No friends yet',
            style: HollowTypography.label.copyWith(color: hollow.textTertiary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowTextLink(
          'Add a friend',
          onTap: () => showFriendsManager(context, tab: FriendsManagerTab.add),
        ),
      ],
    );
  }
}

/// Above this many chips the strip overflows anyway, so it builds lazily
/// rather than measuring every chip to fit.
const int _kEagerChipLimit = 24;

class _FriendStrip extends StatelessWidget {
  final FriendsBarContent content;
  const _FriendStrip({required this.content});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final friends = [...content.leading, ...content.extras];
    final divider = content.extras.isNotEmpty || content.hidden > 0
        ? content.leading.length
        : -1;
    final more = content.hidden > 0;
    final count = friends.length + (divider >= 0 ? 1 : 0) + (more ? 1 : 0);

    Widget item(int index) {
      if (index == divider) {
        return const Padding(
          padding: EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          child: SizedBox(
            height: HollowSpacing.lg + HollowSpacing.xs,
            child: HollowVerticalDivider(),
          ),
        );
      }
      if (more && index == count - 1) {
        return _MoreFriends(hidden: content.hidden);
      }
      final friend =
          friends[divider >= 0 && index > divider ? index - 1 : index];
      return Padding(
        padding: EdgeInsets.only(left: index == 0 ? 0 : HollowSpacing.xs),
        child: _FriendChip(key: ValueKey(friend.peerId), peerId: friend.peerId),
      );
    }

    if (count > _kEagerChipLimit) {
      return EdgeScrollRow.builder(
        semanticLabel: 'friends',
        fadeColor: hollow.opaqueSurface,
        builder: (context, controller) => ListView.builder(
          controller: controller,
          scrollDirection: Axis.horizontal,
          itemCount: count,
          itemBuilder: (context, index) => Center(child: item(index)),
        ),
      );
    }
    return EdgeScrollRow(
      semanticLabel: 'friends',
      fadeColor: hollow.opaqueSurface,
      shrinkWrap: true,
      children: [for (var i = 0; i < count; i++) item(i)],
    );
  }
}

/// How many friends the favourites filter hides; opens the whole list.
class _MoreFriends extends StatelessWidget {
  final int hidden;
  const _MoreFriends({required this.hidden});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: HollowSpacing.xs),
      child: HollowPressable(
        semanticLabel: 'Show all friends, $hidden more',
        onTap: () => showFriendsManager(context),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs,
        ),
        child: Text(
          '+$hidden more',
          style: HollowTypography.label.copyWith(color: hollow.textSecondary),
        ),
      ),
    );
  }
}


/// One friend in the header strip: avatar with presence, name, and an unread
/// count after the name. Unread lifts the name's colour, never its weight, so
/// the row never reflows under the pointer.
class _FriendChip extends ConsumerWidget { // design-ignore: an avatar tab in the friends bar, not a label
  final String peerId;

  const _FriendChip({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    final name = displayNameForPeer(profile, peerId);
    final online =
        ref.watch(onlineIdentitiesProvider.select((s) => s.contains(peerId)));
    final selected =
        ref.watch(selectedPeerProvider.select((id) => id == peerId));
    final enabled = ref.watch(
        notificationSettingsProvider.select((n) => n.isDmEnabled(peerId)));
    final unread = enabled
        ? ref.watch(
            unreadProvider.select((s) => s.dmUnreadCounts[peerId] ?? 0))
        : 0;
    final status = profile?.status ?? '';
    final fill = selected ? hollow.accentMuted : null;

    Widget chip = HollowPressable(
      onTap: () => openDmConversation(ref, peerId),
      semanticLabel: unread > 0 ? '$name, $unread unread' : name,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      backgroundColor: fill,
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.xs,
        HollowSpacing.xs,
        HollowSpacing.sm,
        HollowSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FriendAvatar(peerId: peerId, online: online, restFill: fill),
          const SizedBox(width: HollowSpacing.sm),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kChipNameWidth),
            child: Text(
              name,
              style: HollowTypography.label.copyWith(
                color: selected
                    ? hollow.accentText
                    : unread > 0
                        ? hollow.textPrimary
                        : hollow.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (unread > 0) ...[
            const SizedBox(width: HollowSpacing.xs),
            ExcludeSemantics(child: HollowCountBadge(count: unread)),
          ],
        ],
      ),
    );
    // Their status line, never the name the chip already shows.
    if (status.isNotEmpty) chip = HollowTooltip(message: status, child: chip);

    // The same conversation menu the sidebar DM tile has (issue #61).
    return ContextMenuTarget(
      semanticLabel: 'Conversation actions',
      onOpen: (anchor) => showUserContextMenu(
        context: context,
        ref: ref,
        peerId: peerId,
        surface: UserMenuSurface.dmTile,
        anchor: anchor,
      ),
      child: chip,
    );
  }
}

const double _kChipNameWidth = 96;

/// The avatar with its presence dot, cut out of whatever fill the chip shows
/// right now, so the cut-out never reads as a dark halo.
class _FriendAvatar extends StatelessWidget {
  final String peerId;
  final bool online;
  final Color? restFill;

  const _FriendAvatar(
      {required this.peerId, required this.online, required this.restFill});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hovered = HoverScope.maybeOf(context) ?? false;
    final restFill = this.restFill;
    // The selected fill is a translucent wash, so the cut-out blends it over
    // the strip rather than showing the avatar through.
    final cut = restFill != null
        ? Color.alphaBlend(restFill, hollow.opaqueSurface)
        : hovered
            ? hollow.elevated
            : hollow.opaqueSurface;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        HollowAvatar(peerId: peerId, size: 24),
        Positioned(
          right: -HollowSpacing.xxs,
          bottom: -HollowSpacing.xxs,
          child: AnimatedContainer(
            duration: HollowDurations.fast,
            width: 11,
            height: 11,
            decoration: BoxDecoration(color: cut, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: StatusDot(
              color: online ? hollow.success : hollow.textSecondary,
              size: 7,
              filled: online,
              semanticLabel: online ? 'Online' : 'Offline',
            ),
          ),
        ),
      ],
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

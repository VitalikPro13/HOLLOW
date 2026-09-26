import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/temporary_nickname_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_tab_bar.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/dialogs/confirm_remove_friend.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Friends Manager's tabs.
enum FriendsManagerTab { friends, requests, add }

/// The Friends Manager dialog, open on [tab] (Friends when null); [addFriend]
/// is shorthand for the Add friend tab.
void showFriendsManager(
  BuildContext context, {
  bool addFriend = false,
  FriendsManagerTab? tab,
}) {
  showHollowDialog(
    context: context,
    builder: (context) => _FriendsManager(
      initialTab:
          tab ?? (addFriend ? FriendsManagerTab.add : FriendsManagerTab.friends),
    ),
  );
}

const double _kDialogWidth = 520;
const double _kDialogHeight = 552;

/// Row actions stay on screen on a touch device, which has no hover to find
/// them with.
bool get _isTouch =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Closes the dialog by route identity, whatever else was pushed above it.
void _closeDialog(BuildContext context) {
  final route = ModalRoute.of(context);
  if (route == null || !route.isActive) return;
  final navigator = Navigator.of(context);
  if (route.isCurrent) {
    navigator.pop();
  } else {
    navigator.removeRoute(route);
  }
}

/// The class name is a probe target (`type:_FriendsManager`): keep it.
class _FriendsManager extends ConsumerStatefulWidget {
  final FriendsManagerTab initialTab;
  const _FriendsManager({required this.initialTab});

  @override
  ConsumerState<_FriendsManager> createState() => _FriendsManagerState();
}

class _FriendsManagerState extends ConsumerState<_FriendsManager> {
  late FriendsManagerTab _tab = widget.initialTab;

  // Held here so a half-typed id survives a look at another tab.
  final _addController = TextEditingController();

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  void _pick(FriendsManagerTab tab) => setState(() => _tab = tab);

  @override
  Widget build(BuildContext context) {
    final friends = ref.watch(friendsProvider);
    // HollowDialogCloseButton's own size.
    final closeSize = HollowDialogSurface.isCompact(context) ? 44.0 : 32.0;

    // The accepted list is master-collapsed and deduped by the shared provider.
    // Pending requests stay raw, because the device to master mapping is not
    // usually known until after acceptance.
    final accepted = ref.watch(sortedFriendsProvider);
    final incoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList()
      ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    final outgoing = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'outgoing')
        .toList()
      ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));

    // The tab row is the header: a "Friends" title above a "Friends" tab said
    // the same word twice. The route still announces its name.
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Friends',
      child: HollowDialogSurface(
        width: _kDialogWidth,
        maxHeight: _kDialogHeight,
        padded: false,
        child: SizedBox(
          height: _kDialogHeight,
          child: Column(
            children: [
              // The tabs run to the dialog's edges (its clip rounds the
              // corner) and sit on the divider; the close button gets the same
              // margin above, below and after it.
              Row(
                children: [
                  Expanded(
                    child: _TabBar(
                      selected: _tab,
                      friendCount: accepted.length,
                      waiting: incoming.length,
                      height: closeSize + 2 * HollowSpacing.sm,
                      onPick: _pick,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  const HollowDialogCloseButton(),
                  const SizedBox(width: HollowSpacing.sm),
                ],
              ),
              const HollowDivider(),
              // Switching tabs is instant. Rows sit on the tab row's and the
              // search field's text edge, as in every padded dialog.
              Expanded(
                child: HollowFlushRows(
                  child: switch (_tab) {
                    FriendsManagerTab.friends => _FriendsTab(
                        key: const ValueKey('friends'),
                        accepted: accepted,
                      ),
                    FriendsManagerTab.requests => _RequestsTab(
                        key: const ValueKey('requests'),
                        incoming: incoming,
                        outgoing: outgoing,
                      ),
                    FriendsManagerTab.add => _AddFriendTab(
                        key: const ValueKey('add'),
                        controller: _addController,
                      ),
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  final FriendsManagerTab selected;
  final int friendCount;
  final int waiting;
  final double height;
  final ValueChanged<FriendsManagerTab> onPick;

  const _TabBar({
    required this.selected,
    required this.friendCount,
    required this.waiting,
    required this.height,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return HollowTabBar<FriendsManagerTab>(
      height: height,
      selected: selected,
      onSelected: onPick,
      tabs: [
        HollowChipTab(
          value: FriendsManagerTab.friends,
          label: 'Friends',
          hint: '$friendCount',
        ),
        HollowChipTab(
          value: FriendsManagerTab.requests,
          label: 'Requests',
          count: waiting,
        ),
        const HollowChipTab(
          value: FriendsManagerTab.add,
          label: 'Add friend',
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Friends
// ---------------------------------------------------------------------------

class _FriendsTab extends ConsumerStatefulWidget {
  final List<FriendInfo> accepted;
  const _FriendsTab({super.key, required this.accepted});

  @override
  ConsumerState<_FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends ConsumerState<_FriendsTab> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Moves a favourite among the ones shown. [oldIndex] and [newIndex] count
  /// [shown] only, while the stored list may also hold ids that are no longer
  /// friends, so both are translated to stored positions first.
  void _reorder(List<String> stored, List<String> shown, int oldIndex,
      int newIndex) {
    final moving = shown[oldIndex];
    final from = stored.indexOf(moving);
    if (from < 0) return;
    final after = [...stored]..removeAt(from);
    final rest = [...shown]..removeAt(oldIndex);
    final int to;
    if (newIndex < rest.length) {
      to = after.indexOf(rest[newIndex]);
    } else {
      to = rest.isEmpty ? after.length : after.indexOf(rest.last) + 1;
    }
    if (to < 0) return;
    ref.read(favouriteFriendsProvider.notifier).reorder(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final accepted = widget.accepted;
    final stored = ref.watch(favouriteFriendsProvider);
    final profiles = ref.watch(profileProvider);
    ref.watch(localNicknameProvider);

    if (accepted.isEmpty) {
      return const HollowEmptyState(
        glyph: LucideIcons.users,
        title: 'No friends yet',
        description: 'Add someone from the Add friend tab.',
      );
    }

    // The store keeps masters; ids that are no longer friends stay stored but
    // are not shown.
    final acceptedIds = {for (final f in accepted) f.peerId};
    final favMasters = [
      for (final id in stored)
        if (acceptedIds.contains(id)) id,
    ];

    final q = _query.trim().toLowerCase();
    final search = Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.xl,
        HollowSpacing.lg,
        HollowSpacing.xl,
        HollowSpacing.sm,
      ),
      child: HollowTextField(
        controller: _searchController,
        hintText: 'Search friends',
        prefixIcon:
            Icon(LucideIcons.search, size: 16, color: hollow.textSecondary),
        isDense: true,
        onChanged: (v) => setState(() => _query = v),
      ),
    );

    Widget row(String master, {int? reorderIndex, bool handleSlot = false}) {
      final fav = favMasters.contains(master);
      final last = favMasters.length - 1;
      return _FriendRow(
        key: ValueKey(master),
        peerId: master,
        favourite: fav,
        reorderIndex: reorderIndex,
        handleSlot: handleSlot,
        // The keyboard's path to the drag: Move up and Move down in More.
        onMove: reorderIndex == null
            ? null
            : (delta) {
                final to = reorderIndex + delta;
                if (to < 0 || to > last) return;
                // Post-removal coordinates, as a drag reports them.
                _reorder(stored, favMasters, reorderIndex, to);
              },
        canMoveUp: reorderIndex != null && reorderIndex > 0,
        canMoveDown: reorderIndex != null && reorderIndex < last,
      );
    }

    final listPadding = evenListRowPadding(context, inset: HollowSpacing.xl);

    if (q.isNotEmpty) {
      final matches = accepted.where((f) {
        final name = displayNameFor(profiles, f.peerId).toLowerCase();
        return name.contains(q) || f.peerId.toLowerCase().contains(q);
      }).toList();
      return Column(
        children: [
          search,
          Expanded(
            child: matches.isEmpty
                ? const HollowEmptyState(title: 'No friends match')
                : ListView.builder(
                    padding: listPadding.copyWith(bottom: HollowSpacing.lg),
                    itemCount: matches.length,
                    itemBuilder: (context, i) => row(matches[i].peerId),
                  ),
          ),
        ],
      );
    }

    final others = [
      for (final f in accepted)
        if (!favMasters.contains(f.peerId)) f.peerId,
    ];

    return Column(
      children: [
        search,
        Expanded(
          child: CustomScrollView(
            slivers: [
              if (favMasters.isNotEmpty) ...[
                SliverPadding(
                  padding: listPadding,
                  sliver:
                      const SliverToBoxAdapter(child: _ListLabel('Favourites')),
                ),
                SliverPadding(
                  padding: listPadding,
                  sliver: SliverToBoxAdapter(
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      // It never scrolls, and a clip would cut the rows' hover.
                      clipBehavior: Clip.none,
                      padding: EdgeInsets.zero,
                      buildDefaultDragHandles: false,
                      itemCount: favMasters.length,
                      proxyDecorator: (child, index, animation) =>
                          _DragLift(child: child),
                      onReorderItem: (oldIndex, newIndex) =>
                          _reorder(stored, favMasters, oldIndex, newIndex),
                      itemBuilder: (context, i) =>
                          row(favMasters[i], reorderIndex: i),
                    ),
                  ),
                ),
              ],
              if (others.isNotEmpty) ...[
                SliverPadding(
                  padding: listPadding,
                  sliver:
                      const SliverToBoxAdapter(child: _ListLabel('All friends')),
                ),
                SliverPadding(
                  padding: listPadding.copyWith(bottom: HollowSpacing.lg),
                  sliver: SliverList.builder(
                    itemCount: others.length,
                    // Keeps the actions in the favourites' columns.
                    itemBuilder: (context, i) => row(others[i],
                        handleSlot: favMasters.isNotEmpty),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A section label inside a list, its text on the rows' text edge.
class _ListLabel extends StatelessWidget {
  final String title;
  const _ListLabel(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.md),
      child: HollowSectionHeader(title, dense: true),
    );
  }
}

/// The favourite being dragged: lifted onto the hover surface with the one
/// float shadow. The explicit text style replaces the Material a lift would
/// otherwise need, whose absence underlines text in the drag overlay.
class _DragLift extends StatelessWidget {
  final Widget child;
  const _DragLift({required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // The lift covers the row's hover bleed, not only its content box.
    final bleed = HollowListRow.insetOf(touch: _isTouch);
    return DefaultTextStyle(
      style: HollowTypography.body.copyWith(color: hollow.textPrimary),
      child: HollowBleed(
        horizontal: bleed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: hollow.hover,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            boxShadow: HollowShadows.float,
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: bleed),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// One friend: presence avatar, name and a status line, with Message,
/// favourite and More on hover or keyboard focus. A click on the row opens
/// the conversation too; the Message button is that path for the keyboard.
class _FriendRow extends ConsumerStatefulWidget {
  /// The MASTER identity.
  final String peerId;
  final bool favourite;

  /// Set on a favourite, which can be dragged into a new place.
  final int? reorderIndex;

  /// An empty drag-handle column on a row without one, so its actions line
  /// up with the favourites' above it.
  final bool handleSlot;

  /// Moves a favourite one place up (-1) or down (1).
  final void Function(int delta)? onMove;
  final bool canMoveUp;
  final bool canMoveDown;

  const _FriendRow({
    super.key,
    required this.peerId,
    required this.favourite,
    this.reorderIndex,
    this.handleSlot = false,
    this.onMove,
    this.canMoveUp = false,
    this.canMoveDown = false,
  });

  @override
  ConsumerState<_FriendRow> createState() => _FriendRowState();
}

class _FriendRowState extends ConsumerState<_FriendRow> {
  bool _hovered = false;

  // The row's actions stay up while its menu is open: the menu route takes the
  // pointer, so the row would read as un-hovered under it.
  bool _menuOpen = false;
  bool _focused = false;

  void _message() {
    openDmConversation(ref, widget.peerId);
    _closeDialog(context);
  }

  void _toggleFavourite() {
    ref.read(favouriteFriendsProvider.notifier).toggle(widget.peerId);
  }

  /// The same start as the DM header: TURN check, the leave-the-room
  /// confirm, then the call in its DM, and the manager closes behind it.
  Future<void> _call() => startDmCallFlow(context, ref, widget.peerId,
      beforeCall: () => _closeDialog(context));

  void _openMenu(Offset anchor, {bool alignEnd = false}) {
    final master = widget.peerId;
    setState(() => _menuOpen = true);
    showHollowMenu(
      context: context,
      anchor: anchor,
      alignEnd: alignEnd,
      // menuRef is deliberately NOT named `ref`: it dies with the menu, while
      // the actions run after it closes.
      builder: (_, menuRef) {
        final online = menuRef.watch(onlineIdentitiesProvider).contains(master);
        final inCall = menuRef.watch(callProvider.select((c) => c.status)) !=
            CallStatus.idle;
        final localNick = menuRef.watch(localNicknameProvider)[master];
        final name = displayNameForPeer(
            menuRef.watch(profileProvider.select((p) => p[master])), master);
        return [
          if (online && !inCall)
            HollowMenuItem(
              icon: LucideIcons.phone,
              label: 'Voice call',
              onTap: _call,
            ),
          HollowMenuItem(
            icon: LucideIcons.user,
            label: 'View profile',
            onTap: () {
              if (!mounted) return;
              showProfileCardPopup(
                context: context,
                ref: ref,
                peerId: master,
                anchorOf: () => anchor,
              );
            },
          ),
          HollowMenuItem(
            icon: localNick != null ? LucideIcons.pencil : LucideIcons.tag,
            label: localNick != null ? 'Edit nickname' : 'Set a nickname',
            onTap: () {
              if (!mounted) return;
              showLocalNicknameDialog(context, ref, master,
                  currentNickname: localNick ?? '');
            },
          ),
          if (widget.onMove != null && widget.canMoveUp)
            HollowMenuItem(
              icon: LucideIcons.arrowUp,
              label: 'Move up',
              onTap: () => widget.onMove!(-1),
            ),
          if (widget.onMove != null && widget.canMoveDown)
            HollowMenuItem(
              icon: LucideIcons.arrowDown,
              label: 'Move down',
              onTap: () => widget.onMove!(1),
            ),
          const HollowMenuDivider(),
          HollowMenuItem(
            icon: LucideIcons.userMinus,
            label: 'Remove friend',
            isDanger: true,
            onTap: () => confirmRemoveFriend(context, ref,
                peerId: widget.peerId, name: name),
          ),
        ];
      },
    ).whenComplete(() {
      if (mounted) setState(() => _menuOpen = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final peerId = widget.peerId;
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    ref.watch(localNicknameProvider);
    final name = displayNameForPeer(profile, peerId);
    final online =
        ref.watch(onlineIdentitiesProvider.select((s) => s.contains(peerId)));
    final status = profile?.status.trim() ?? '';
    final line = online && status.isNotEmpty
        ? status
        : (online ? 'Online' : 'Offline');

    final touch = _isTouch;
    final buttonSize = touch ? 44.0 : 32.0;
    final showActions = touch || _hovered || _focused || _menuOpen;

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowIconButton(
          icon: LucideIcons.messageCircle,
          label: 'Message $name',
          tooltip: 'Message',
          size: buttonSize,
          onPressed: _message,
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowIconButton(
          icon: widget.favourite ? Icons.star_rounded : LucideIcons.star,
          label: widget.favourite
              ? 'Remove from favourites'
              : 'Add to favourites',
          color: widget.favourite ? hollow.textPrimary : hollow.textSecondary,
          size: buttonSize,
          onPressed: _toggleFavourite,
        ),
        const SizedBox(width: HollowSpacing.xs),
        Builder(
          builder: (buttonContext) => HollowIconButton(
            icon: LucideIcons.ellipsis,
            label: 'More for $name',
            tooltip: 'More',
            size: buttonSize,
            onPressed: () {
              final box = buttonContext.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              _openMenu(
                overlayAnchorOf(buttonContext,
                    localOffset: Offset(box.size.width, box.size.height)),
                alignEnd: true,
              );
            },
          ),
        ),
        if (widget.reorderIndex != null) ...[
          const SizedBox(width: HollowSpacing.xs),
          // Pointer only; the keyboard moves a favourite from More.
          ReorderableDragStartListener(
            index: widget.reorderIndex!,
            child: Semantics(
              label: 'Drag to reorder $name',
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: SizedBox.square(
                  dimension: buttonSize,
                  child: Icon(LucideIcons.gripVertical,
                      size: 16, color: hollow.textTertiary),
                ),
              ),
            ),
          ),
        ] else if (widget.handleSlot) ...[
          const SizedBox(width: HollowSpacing.xs),
          SizedBox.square(dimension: buttonSize),
        ],
      ],
    );

    final row = HollowListRow(
      onTap: _message,
      leading: PresenceAvatar(
        peerId: peerId,
        size: 32,
        online: online,
        // The ring is cut from the surface under the dot: the row's hover
        // fill while hovered.
        ring: _hovered ? hollow.elevated : hollow.overlay,
      ),
      title: name,
      subtitle: line,
      // Hidden, never removed: the buttons stay in the focus order, and a Tab
      // onto one is what shows them.
      trailing: AnimatedOpacity(
        opacity: showActions ? 1 : 0,
        duration: HollowDurations.fast,
        alwaysIncludeSemantics: true,
        child: actions,
      ),
    );

    return ContextMenuTarget(
      semanticLabel: 'Friend actions',
      onOpen: _openMenu,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: row,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

class _RequestsTab extends ConsumerStatefulWidget {
  final List<FriendInfo> incoming;
  final List<FriendInfo> outgoing;

  const _RequestsTab({
    super.key,
    required this.incoming,
    required this.outgoing,
  });

  @override
  ConsumerState<_RequestsTab> createState() => _RequestsTabState();
}

class _RequestsTabState extends ConsumerState<_RequestsTab> {
  /// Requests with an answer in flight, keyed by peer id, to the button that
  /// is loading.
  final Map<String, String> _busy = {};

  /// Awaits a friend-request mutation and surfaces failure: the notifier
  /// rethrows, and a silent drop leaves the row stuck with no feedback.
  Future<void> _answer(String peerId, String which,
      Future<void> Function() action, String failMsg) async {
    if (_busy.containsKey(peerId)) return;
    setState(() => _busy[peerId] = which);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, failMsg, type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(peerId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(profileProvider);
    final links = ref.watch(deviceLinkProvider);
    ref.watch(localNicknameProvider);
    final friends = ref.read(friendsProvider.notifier);

    Widget requestRow(FriendInfo req, {required bool incoming}) {
      // DISPLAY only: a request added by nickname can be keyed under a device
      // id until the re-key lands, and resolving heals the name and avatar.
      // Answers still target `req.peerId`, which is reachable.
      final displayId = links.identityOf(req.peerId);
      final chosen = chosenNameForPeer(profiles[displayId], displayId);
      final at = DateTime.fromMillisecondsSinceEpoch(req.requestedAt);
      final busy = _busy[req.peerId];

      return HollowListRow(
        leading: HollowAvatar(peerId: displayId, size: 32),
        title: chosen ?? displayId,
        subtitle: incoming ? receivedRequestLabel(at) : sentRequestLabel(at),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (incoming) ...[
              HollowButton.ghost(
                compact: true,
                touch: _isTouch,
                semanticLabel: 'Decline friend request',
                loading: busy == 'reject',
                onPressed: () => _answer(
                    req.peerId,
                    'reject',
                    () => friends.rejectRequest(req.peerId),
                    'Could not decline request'),
                child: const Text('Decline'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.outline(
                compact: true,
                touch: _isTouch,
                semanticLabel: 'Accept friend request',
                loading: busy == 'accept',
                onPressed: () => _answer(
                    req.peerId,
                    'accept',
                    () => friends.acceptRequest(req.peerId),
                    'Could not accept request'),
                child: const Text('Accept'),
              ),
            ] else
              HollowButton.ghost(
                compact: true,
                touch: _isTouch,
                semanticLabel: 'Cancel friend request',
                loading: busy == 'cancel',
                onPressed: () => _answer(
                    req.peerId,
                    'cancel',
                    () => friends.rejectRequest(req.peerId),
                    'Could not cancel request'),
                child: const Text('Cancel request'),
              ),
          ],
        ),
      );
    }

    return ListView(
      padding: evenListRowPadding(context, inset: HollowSpacing.xl)
          .copyWith(bottom: HollowSpacing.lg),
      children: [
        const _ListLabel('Received'),
        if (widget.incoming.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: HollowSpacing.xs),
            child: HollowEmptyState(title: 'No requests waiting', dense: true),
          )
        else
          for (final r in widget.incoming)
            KeyedSubtree(
              key: ValueKey('in:${r.peerId}'),
              child: requestRow(r, incoming: true),
            ),
        if (widget.outgoing.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          const _ListLabel('Sent'),
          for (final r in widget.outgoing)
            KeyedSubtree(
              key: ValueKey('out:${r.peerId}'),
              child: requestRow(r, incoming: false),
            ),
        ],
      ],
    );
  }
}

/// The line under a received request; shared with the phone.
String receivedRequestLabel(DateTime at) {
  final when = conversationTimeLabel(at);
  return when.isEmpty ? 'Wants to be friends' : 'Wants to be friends · $when';
}

/// "Sent today", "Sent yesterday", "Sent Mon", "Sent Sep 17"; shared with the
/// phone.
String sentRequestLabel(DateTime at) {
  final label = conversationTimeLabel(at);
  if (label.isEmpty) return 'Request sent';
  if (label.contains(':')) return 'Sent today';
  if (label == 'Yesterday') return 'Sent yesterday';
  return 'Sent $label';
}

// ---------------------------------------------------------------------------
// Add friend
// ---------------------------------------------------------------------------

/// Whether [input] is a peer id rather than a temporary nickname.
bool isPeerIdInput(String input) => input.startsWith('12D3KooW');

/// Nickname lookups a send is waiting on, by lowercased nickname.
final Map<String, Completer<void>> _nicknameLookups = {};

/// Called by event_provider when the relay could not resolve [nickname].
/// True when a send was waiting on it, so the caller shows no second message.
bool handleNicknameLookupFailed(String nickname, String error) {
  var waiter = _nicknameLookups[nickname.toLowerCase()];
  if (waiter == null && _nicknameLookups.length == 1) {
    waiter = _nicknameLookups.values.single;
  }
  if (waiter == null || waiter.isCompleted) return false;
  waiter.completeError(FriendlyException(error == 'not_found'
      ? 'No one has the nickname $nickname right now. Nicknames reset when '
          'their owner goes offline.'
      : "Hollow couldn't look up that nickname. Try again."));
  return true;
}

Map<String, int> _outgoing(Map<String, FriendInfo> friends) => {
      for (final f in friends.values)
        if (f.status == 'pending' && f.direction == 'outgoing')
          f.peerId: f.requestedAt,
    };

/// Sends a friend request to a peer id or a temporary nickname; rethrows so
/// the caller keeps the input for a retry. A nickname completes only once the
/// relay has answered and the request exists, so a caller's busy state and
/// its success message are both true.
Future<void> sendFriendRequestTo(WidgetRef ref, String input) async {
  if (isPeerIdInput(input)) {
    await ref.read(friendsProvider.notifier).sendRequest(input);
    return;
  }
  final key = input.toLowerCase();
  final before = _outgoing(ref.read(friendsProvider));
  final sent = Completer<void>();
  _nicknameLookups[key] = sent;
  final sub = ref.listenManual(friendsProvider, (_, next) {
    final now = _outgoing(next);
    final changed = now.entries.any((e) => before[e.key] != e.value);
    if (changed && !sent.isCompleted) sent.complete();
  });
  try {
    await network_api.sendFriendRequestByNickname(nickname: input);
    await sent.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw const FriendlyException(
          "Hollow didn't hear back about that nickname. Try again."),
    );
  } finally {
    sub.close();
    if (identical(_nicknameLookups[key], sent)) _nicknameLookups.remove(key);
  }
}

const kAddFriendHint = 'Paste an ID, or type a nickname';
const kAddFriendNote = "They see your request the next time they're online.";

/// Add friend tab, taking either a peer id or a nickname.
class _AddFriendTab extends ConsumerStatefulWidget {
  final TextEditingController controller;
  const _AddFriendTab({super.key, required this.controller});

  @override
  ConsumerState<_AddFriendTab> createState() => _AddFriendTabState();
}

class _AddFriendTabState extends ConsumerState<_AddFriendTab> {
  bool _sending = false;
  String? _error;

  Future<void> _send() async {
    final input = widget.controller.text.trim();
    if (input.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    // Awaited, a nickname until the relay answers, so the button stays busy
    // through the lookup and the input is kept for a retry.
    try {
      await sendFriendRequestTo(ref, input);
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _error = friendlyError(e,
              fallback: "Couldn't send the request. Try again.");
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _sending = false);
    widget.controller.clear();
    HollowToast.show(context, 'Friend request sent',
        type: HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsFieldLabel(label: 'User ID or nickname'),
          const SizedBox(height: HollowSpacing.sm),
          // Baseline, not centre: an error line under the field would pull a
          // centred button down out of line with the field.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: HollowTextField(
                  controller: widget.controller,
                  hintText: kAddFriendHint,
                  autofocus: true,
                  style: HollowTypography.mono
                      .copyWith(color: hollow.textPrimary),
                  errorText: _error,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                onPressed: _send,
                loading: _sending,
                child: const Text('Send request'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(kAddFriendNote,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary)),
          const SizedBox(height: HollowSpacing.xl),
          const HowOthersAddYou(),
        ],
      ),
    );
  }
}

/// Your ID to copy and a temporary nickname to claim: the other direction of
/// adding a friend. Shared by the dialog and the phone's add-friend sheet.
class HowOthersAddYou extends ConsumerStatefulWidget {
  const HowOthersAddYou({super.key});

  @override
  ConsumerState<HowOthersAddYou> createState() => _HowOthersAddYouState();
}

class _HowOthersAddYouState extends ConsumerState<HowOthersAddYou> {
  final _claimController = TextEditingController();
  bool _releasing = false;

  @override
  void dispose() {
    _claimController.dispose();
    super.dispose();
  }

  // The typed name stays until the relay answers: a taken or invalid name is
  // corrected, not retyped. It clears once the claim lands.
  Future<void> _claim() async {
    final nickname = _claimController.text.trim().toLowerCase();
    if (nickname.isEmpty) return;
    final notifier = ref.read(temporaryNicknameProvider.notifier);
    try {
      await notifier.claim(nickname);
    } catch (_) {
      // The relay never heard it, so no answer will end the claiming state.
      if (mounted) notifier.onClaimFailed('send');
    }
  }

  Future<void> _release() async {
    setState(() => _releasing = true);
    try {
      await ref.read(temporaryNicknameProvider.notifier).release();
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't release the nickname. Try again."),
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _releasing = false);
    }
  }

  Future<void> _copyId(String id) async {
    await Clipboard.setData(ClipboardData(text: id));
    if (mounted) {
      HollowToast.show(context, 'ID copied', type: HollowToastType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final nicknameState = ref.watch(temporaryNicknameProvider);
    // A claim travels to the relay, so without our link it can only spin.
    final link = ref.watch(overallConnectionProvider);
    final offline = link == OverallConnection.offline ||
        link == OverallConnection.reconnecting ||
        link == OverallConnection.error;
    ref.listen(temporaryNicknameProvider, (_, next) {
      if (next.status == NicknameStatus.claimed) _claimController.clear();
    });
    final myId = ref.watch(identityProvider).peerId ?? '';
    final touch = _isTouch;
    final title = HollowTypography.label.copyWith(color: hollow.textPrimary);
    final mono = HollowTypography.mono.copyWith(color: hollow.textPrimary);
    final secondary =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const HollowSectionHeader('How others add you'),
        const SizedBox(height: HollowSpacing.xs),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your user ID', style: title),
                  const SizedBox(height: HollowSpacing.xxs),
                  Text(
                    myId,
                    style: HollowTypography.mono
                        .copyWith(color: hollow.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            HollowButton.ghost(
              compact: !touch,
              touch: touch,
              semanticLabel: 'Copy your user ID',
              onPressed: myId.isEmpty ? null : () => _copyId(myId),
              child: const Text('Copy'),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.lg),
        Text('Temporary nickname', style: title),
        const SizedBox(height: HollowSpacing.xxs),
        Text('A short name instead of your ID. Resets when you go offline.',
            style: secondary),
        const SizedBox(height: HollowSpacing.sm),
        if (nicknameState.status == NicknameStatus.claimed)
          Row(
            children: [
              Expanded(
                child: Text(
                  nicknameState.nickname ?? '',
                  style: mono,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.ghost(
                compact: !touch,
                touch: touch,
                loading: _releasing,
                onPressed: _release,
                child: const Text('Release'),
              ),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: HollowTextField(
                  controller: _claimController,
                  hintText: 'Choose a nickname',
                  style: mono,
                  onSubmitted: (_) => _claim(),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.outline(
                touch: touch,
                onPressed: offline ? null : _claim,
                loading: nicknameState.status == NicknameStatus.claiming,
                child: const Text('Claim'),
              ),
            ],
          ),
        if (offline && nicknameState.status != NicknameStatus.claimed) ...[
          const SizedBox(height: HollowSpacing.sm),
          const HollowEmptyState(
            dense: true,
            title: "You're offline",
            description: "Claim a nickname once you're back.",
          ),
        ] else if (nicknameState.status == NicknameStatus.failed &&
            nicknameState.error != null) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            _claimError(nicknameState.error!),
            style: HollowTypography.bodySmall.copyWith(color: hollow.error),
          ),
        ],
      ],
    );
  }
}

String _claimError(String error) => switch (error) {
      'taken' => 'That nickname is already taken',
      'invalid' => 'Use 3 to 20 lowercase letters, numbers or underscores',
      'timeout' => "The relay didn't answer. Try again.",
      _ => 'Could not claim that nickname',
    };

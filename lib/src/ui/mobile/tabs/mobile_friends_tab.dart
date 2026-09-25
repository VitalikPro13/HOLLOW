import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart'
    show showLocalNicknameDialog;
import 'package:hollow/src/ui/dialogs/confirm_remove_friend.dart';
import 'package:hollow/src/ui/dialogs/friends_manager_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
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
    final friends = ref.watch(friendsProvider);
    ref.watch(profileProvider);
    final favourites = ref.watch(favouriteFriendsProvider);
    final links = ref.watch(deviceLinkProvider);
    ref.watch(localNicknameProvider);

    // Accepted friends arrive master-collapsed and deduped, so a friend
    // stranded under a DEVICE id does not appear twice. Pending requests stay
    // raw, their mapping being unknown until acceptance.
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
    incoming.sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    outgoing.sort((a, b) => b.requestedAt.compareTo(a.requestedAt));

    // Resolved device to master first, so a favourite saved under a device id
    // still matches its collapsed friend row.
    final favMasters = favourites.map(links.identityOf).toList();
    int favRank(String peerId) {
      final i = favMasters.indexOf(peerId);
      return i < 0 ? favMasters.length : i;
    }
    bool isFav(String peerId) => favMasters.contains(peerId);

    final favFriends = <FriendInfo>[];
    final otherFriends = <FriendInfo>[];

    for (final f in accepted) {
      final name = _resolvedName(f.peerId);
      if (_searchQuery.isNotEmpty &&
          !name.toLowerCase().contains(_searchQuery)) {
        continue;
      }
      if (isFav(f.peerId)) {
        favFriends.add(f);
      } else {
        otherFriends.add(f);
      }
    }

    favFriends.sort((a, b) => favRank(a.peerId).compareTo(favRank(b.peerId)));

    final showRequests = _searchQuery.isEmpty;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.sm,
            ),
            child: Column(
              children: [
                HollowTextField(
                  controller: _searchController,
                  hintText: 'Search friends',
                  prefixIcon: const Icon(LucideIcons.search, size: 16),
                  isDense: true,
                ),
                const SizedBox(height: HollowSpacing.sm),
                HollowButton.outline(
                  touch: true,
                  onPressed: () => showMobileAddFriendSheet(context),
                  icon: const Icon(LucideIcons.userPlus, size: 16),
                  expand: true,
                  child: const Text('Add friend'),
                ),
              ],
            ),
          ),
        ),

        if (showRequests && incoming.isNotEmpty) ...[
          _sectionHeaderSliver('Received', incoming.length),
          SliverList.builder(
            itemCount: incoming.length,
            itemBuilder: (context, index) => _PendingRow(
              key: ValueKey('in:${incoming[index].peerId}'),
              request: incoming[index],
              isIncoming: true,
            ),
          ),
        ],

        if (showRequests && outgoing.isNotEmpty) ...[
          _sectionHeaderSliver('Sent', outgoing.length),
          SliverList.builder(
            itemCount: outgoing.length,
            itemBuilder: (context, index) => _PendingRow(
              key: ValueKey('out:${outgoing[index].peerId}'),
              request: outgoing[index],
              isIncoming: false,
            ),
          ),
        ],

        if (favFriends.isNotEmpty) ...[
          _sectionHeaderSliver('Favourites', favFriends.length),
          SliverList.builder(
            itemCount: favFriends.length,
            itemBuilder: (context, index) => _FriendRow(
              key: ValueKey(favFriends[index].peerId),
              peerId: favFriends[index].peerId,
              isFavourite: true,
              // A phone has no drag, so the order moves from the sheet, as
              // Move up and Move down do in the desktop Friends Manager.
              onMove: (delta) => _moveFavourite(
                  [for (final f in favFriends) f.peerId], index, delta),
              canMoveUp: index > 0,
              canMoveDown: index < favFriends.length - 1,
            ),
          ),
        ],

        if (otherFriends.isNotEmpty) ...[
          _sectionHeaderSliver('All friends', otherFriends.length),
          SliverList.builder(
            itemCount: otherFriends.length,
            itemBuilder: (context, index) => _FriendRow(
              key: ValueKey(otherFriends[index].peerId),
              peerId: otherFriends[index].peerId,
            ),
          ),
        ],

        if (accepted.isEmpty && incoming.isEmpty && outgoing.isEmpty)
          const SliverToBoxAdapter(
            child: HollowEmptyState(
              glyph: LucideIcons.users,
              title: 'No friends yet',
              description: 'Add someone by their ID or nickname.',
            ),
          )
        else if (accepted.isNotEmpty &&
            _searchQuery.isNotEmpty &&
            favFriends.isEmpty &&
            otherFriends.isEmpty)
          const SliverToBoxAdapter(
            child: HollowEmptyState(title: 'No friends match'),
          ),

        const SliverPadding(padding: EdgeInsets.only(bottom: HollowSpacing.xl)),
      ],
    );
  }

  /// Moves the shown favourite at [index] one place by [delta], in the stored
  /// list the desktop reorders too.
  void _moveFavourite(List<String> shown, int index, int delta) {
    final to = index + delta;
    if (to < 0 || to >= shown.length) return;
    final links = ref.read(deviceLinkProvider);
    final notifier = ref.read(favouriteFriendsProvider.notifier);
    final stored = [
      for (final id in ref.read(favouriteFriendsProvider)) links.identityOf(id),
    ];
    final from = stored.indexOf(shown[index]);
    final past = stored.indexOf(shown[to]);
    if (from < 0 || past < 0) return;
    notifier.reorder(from, past).catchError((Object _) {
      if (mounted) {
        HollowToast.show(context, 'Could not move the favourite',
            type: HollowToastType.error);
      }
    });
  }

  String _resolvedName(String peerId) {
    final nicknames = ref.read(localNicknameProvider);
    final profiles = ref.read(profileProvider);
    return nicknames[peerId] ?? displayNameFor(profiles, peerId);
  }
}

/// The phone's add-friend sheet: a peer id or nickname, then the request.
void showMobileAddFriendSheet(BuildContext context) {
  showHollowSheet(
    context: context,
    scrollControlled: true,
    builder: (_) => const _AddFriendSheet(),
  );
}

Widget _sectionHeaderSliver(String title, int count) => SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(
          left: HollowSpacing.lg, right: HollowSpacing.lg, top: HollowSpacing.md,
        ),
        child: HollowSectionHeader(title, count: '$count', dense: true),
      ),
    );

void _openChat(BuildContext context, WidgetRef ref, String peerId) {
  ref.read(selectedPeerProvider.notifier).state = peerId;
  Navigator.of(context, rootNavigator: true).push(
    hollowMobileRoute(
      settings: const RouteSettings(name: MobileChatRoute.routeName),
      builder: (_) => MobileChatRoute(peerId: peerId),
    ),
  ).then((_) {
    // Guarded: a notification tap may have replaced this chat already.
    if (ref.read(selectedPeerProvider) == peerId) {
      ref.read(selectedPeerProvider.notifier).state = null;
    }
  });
}

class _FriendRow extends ConsumerWidget {
  final String peerId;
  final bool isFavourite;
  final void Function(int delta)? onMove;
  final bool canMoveUp;
  final bool canMoveDown;

  const _FriendRow({
    super.key,
    required this.peerId,
    this.isFavourite = false,
    this.onMove,
    this.canMoveUp = false,
    this.canMoveDown = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    final localNicknames = ref.watch(localNicknameProvider);
    final isOnline = identityIsOnline(ref, peerId);
    final name = localNicknames[peerId] ?? displayNameForPeer(profile, peerId);
    final status = profile?.status.trim() ?? '';
    final line = isOnline && status.isNotEmpty
        ? status
        : (isOnline ? 'Online' : 'Offline');

    return HollowPressable(
      onTap: () => _openChat(context, ref, peerId),
      onLongPress: () => _showActions(context, ref),
      subtle: true,
      semanticButton: false,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          PresenceAvatar(
            peerId: peerId,
            size: 40,
            online: isOnline,
            ring: hollow.background,
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: HollowTypography.bodyTouch.copyWith(
                      color:
                          isOnline ? hollow.textPrimary : hollow.textSecondary,
                    ),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(line,
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textTertiary),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.read(profileProvider);
    final localNicknames = ref.read(localNicknameProvider);
    // Resolved to the master inside, so a friend favourited under a device
    // id is not offered "Add to favourites" again.
    final isFav =
        ref.read(favouriteFriendsProvider.notifier).isFavourite(peerId);
    final localNick = localNicknames[peerId];
    final name = localNick ?? displayNameFor(profiles, peerId);
    // As on desktop: a call is offered only when it can start.
    final canCall = ref.read(onlineIdentitiesProvider).contains(peerId) &&
        ref.read(callProvider).status == CallStatus.idle;

    Widget row(IconData icon, String label, VoidCallback onTap) =>
        HollowListRow(
          touch: true,
          title: label,
          leading: Icon(icon, size: 20, color: hollow.textSecondary),
          onTap: () {
            Navigator.pop(context);
            onTap();
          },
        );

    // The sheet's labels are the desktop person menu's.
    showHollowSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowSheetTitle(name),
            row(LucideIcons.messageCircle, 'Message',
                () => _openChat(context, ref, peerId)),
            if (canCall)
              row(LucideIcons.phone, 'Start a call',
                  () => startMobileDmCall(context, ref, peerId)),
            row(LucideIcons.user, 'Profile',
                () => showMobileProfileSheet(context, peerId: peerId)),
            row(isFav ? LucideIcons.starOff : LucideIcons.star,
                isFav ? 'Remove favourite' : 'Add to favourites',
                () => ref.read(favouriteFriendsProvider.notifier).toggle(peerId)),
            if (onMove != null && canMoveUp)
              row(LucideIcons.arrowUp, 'Move up', () => onMove!(-1)),
            if (onMove != null && canMoveDown)
              row(LucideIcons.arrowDown, 'Move down', () => onMove!(1)),
            row(LucideIcons.tag,
                localNick != null ? 'Edit nickname' : 'Set nickname',
                () => showLocalNicknameDialog(context, ref, peerId,
                    currentNickname: localNick ?? '')),
            const HollowDivider(),
            row(LucideIcons.userMinus, 'Remove friend',
                () => confirmRemoveFriend(context, ref,
                    peerId: peerId, name: name)),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// A request waiting on an answer: Decline and Accept when it came to us,
/// Cancel request when we sent it.
class _PendingRow extends ConsumerStatefulWidget {
  final FriendInfo request;
  final bool isIncoming;

  const _PendingRow({
    super.key,
    required this.request,
    required this.isIncoming,
  });

  @override
  ConsumerState<_PendingRow> createState() => _PendingRowState();
}

class _PendingRowState extends ConsumerState<_PendingRow> {
  /// The answer in flight, if any, whose button shows loading.
  String? _busy;

  Future<void> _answer(String which, Future<void> Function() action,
      String failure, {String? success}) async {
    if (_busy != null) return;
    setState(() => _busy = which);
    try {
      await action();
      if (success != null && mounted) {
        HollowToast.show(context, success, type: HollowToastType.success);
      }
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, failure, type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final peerId = widget.request.peerId;
    // DISPLAY only: a request added by nickname can be keyed under a device id
    // until the re-key lands. Answers still target the raw id.
    final displayId = ref.watch(deviceLinkProvider).identityOf(peerId);
    final profile = ref.watch(profileProvider.select((p) => p[displayId]));
    ref.watch(localNicknameProvider);
    final chosen = chosenNameForPeer(profile, displayId);
    final at = DateTime.fromMillisecondsSinceEpoch(widget.request.requestedAt);
    final friends = ref.read(friendsProvider.notifier);

    final actions = <Widget>[
      if (widget.isIncoming) ...[
        HollowButton.ghost(
          touch: true,
          semanticLabel: 'Decline friend request',
          loading: _busy == 'decline',
          onPressed: () => _answer('decline',
              () => friends.rejectRequest(peerId),
              'Could not decline request'),
          child: const Text('Decline'),
        ),
        HollowButton.outline(
          touch: true,
          semanticLabel: 'Accept friend request',
          loading: _busy == 'accept',
          onPressed: () => _answer('accept',
              () => friends.acceptRequest(peerId),
              'Could not accept request'),
          child: const Text('Accept'),
        ),
      ] else
        HollowButton.ghost(
          touch: true,
          semanticLabel: 'Cancel friend request',
          loading: _busy == 'cancel',
          onPressed: () => _answer('cancel',
              () => friends.rejectRequest(peerId),
              'Could not cancel request'),
          child: const Text('Cancel request'),
        ),
    ];
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(chosen ?? displayId,
            style: (chosen != null
                    ? HollowTypography.bodyTouch
                    : HollowTypography.mono)
                .copyWith(color: hollow.textPrimary),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        Text(
            widget.isIncoming
                ? receivedRequestLabel(at)
                : sentRequestLabel(at),
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textTertiary),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
    // Larger Text: the buttons cannot share a phone's line with the name, so
    // they wrap under it.
    final stacked = MediaQuery.textScalerOf(context).scale(10) > 13;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment:
            stacked ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          HollowAvatar(peerId: displayId, size: 40),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      info,
                      const SizedBox(height: HollowSpacing.sm),
                      Wrap(
                        spacing: HollowSpacing.sm,
                        runSpacing: HollowSpacing.sm,
                        children: actions,
                      ),
                    ],
                  )
                : info,
          ),
          if (!stacked) ...[
            const SizedBox(width: HollowSpacing.sm),
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) const SizedBox(width: HollowSpacing.sm),
              actions[i],
            ],
          ],
        ],
      ),
    );
  }
}

class _AddFriendSheet extends ConsumerStatefulWidget {
  const _AddFriendSheet();

  @override
  ConsumerState<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<_AddFriendSheet> {
  final _inputController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final input = _inputController.text.trim();
    if (input.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await sendFriendRequestTo(ref, input);
      if (mounted) {
        Navigator.of(context).pop();
        HollowToast.show(context, 'Friend request sent',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't send the request. Try again."),
            type: HollowToastType.error);
        setState(() => _sending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.only(
              left: HollowSpacing.lg,
              right: HollowSpacing.lg,
              bottom: HollowSpacing.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add friend',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
                const SizedBox(height: HollowSpacing.lg),
                const SettingsFieldLabel(label: 'User ID or nickname'),
                const SizedBox(height: HollowSpacing.sm),
                HollowTextField(
                  controller: _inputController,
                  hintText: kAddFriendHint,
                  autofocus: true,
                  style: HollowTypography.mono
                      .copyWith(color: hollow.textPrimary),
                  onSubmitted: (_) => _send(),
                ),
                const SizedBox(height: HollowSpacing.sm),
                Text(kAddFriendNote,
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textSecondary)),
                const SizedBox(height: HollowSpacing.md),
                // Directly under the input, with no competing buttons between.
                HollowButton.filled(
                  touch: true,
                  onPressed: _send,
                  loading: _sending,
                  expand: true,
                  child: const Text('Send request'),
                ),
                const SizedBox(height: HollowSpacing.xl),
                const HowOthersAddYou(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

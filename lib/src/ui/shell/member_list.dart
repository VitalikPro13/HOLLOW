import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/person_row.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/components/support_glyph.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// One line of a server's member list: a group's header or a person.
sealed class MemberListItem {
  const MemberListItem();
}

class MemberGroupItem extends MemberListItem {
  /// Also the fold key, per server.
  final String label;
  final int count;
  final bool folded;

  const MemberGroupItem(this.label, this.count, {required this.folded});
}

class MemberPersonItem extends MemberListItem {
  final crdt_api.MemberFfi member;
  final bool online;

  const MemberPersonItem(this.member, {required this.online});
}

const _roleOrder = ['owner', 'admin', 'moderator', 'member'];

/// A server's members, online first and grouped by role, then Offline.
///
/// A folded group keeps its header and full count; only its rows go away. A
/// role shows as its group's header and never again on the rows under it.
final memberListProvider = Provider.autoDispose
    .family<AsyncValue<List<MemberListItem>>, String>((ref, serverId) {
  final membersAsync = ref.watch(serverMembersProvider(serverId));
  // Folds device to master and applies invisibility already.
  final onlineIdentities = ref.watch(onlineIdentitiesProvider);
  final me = ref.watch(identityProvider).peerId;
  final amInvisible = ref.watch(invisibleModeProvider);
  final foldedKeys = ref.watch(collapsedMemberGroupsProvider);

  return membersAsync.whenData((members) {
    bool isOnline(crdt_api.MemberFfi m) =>
        m.peerId == me ? !amInvisible : onlineIdentities.contains(m.peerId);
    String sortName(crdt_api.MemberFfi m) =>
        (m.nickname.isNotEmpty ? m.nickname : m.displayName).toLowerCase();
    int byName(crdt_api.MemberFfi a, crdt_api.MemberFfi b) =>
        sortName(a).compareTo(sortName(b));

    final online = members.where(isOnline).toList()..sort(byName);
    final offline = members.where((m) => !isOnline(m)).toList()..sort(byName);

    final items = <MemberListItem>[];
    void addGroup(String label, List<crdt_api.MemberFfi> group, bool on) {
      if (group.isEmpty) return;
      final folded = foldedKeys
          .contains(CollapsedMemberGroupsNotifier.keyFor(serverId, label));
      items.add(MemberGroupItem(label, group.length, folded: folded));
      if (folded) return;
      for (final m in group) {
        items.add(MemberPersonItem(m, online: on));
      }
    }

    // Plain members (and any role this build does not know) sit under
    // "Online", after every role that has a group of its own.
    String groupOf(crdt_api.MemberFfi m) =>
        _roleOrder.contains(m.role) ? m.role : 'member';
    for (final role in _roleOrder) {
      addGroup(role == 'member' ? 'Online' : roleDisplayName(role),
          [for (final m in online) if (groupOf(m) == role) m], true);
    }
    addGroup('Offline', offline, false);
    return items;
  });
});

/// The member list of one server, shared by the desktop member panel and the
/// phone's member sheet.
class MemberList extends ConsumerWidget {
  final String serverId;

  /// Phone metrics, and a tap opens the profile sheet instead of the card.
  final bool touch;

  final ScrollController? scrollController;

  /// Extra room under the last row (a phone's home indicator).
  final double bottomInset;

  const MemberList({
    super.key,
    required this.serverId,
    this.touch = false,
    this.scrollController,
    this.bottomInset = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(memberListProvider(serverId));
    final link = ref.watch(overallConnectionProvider);
    // Presence rides our relay link, so without it everyone else reads as
    // offline; saying why beats a list that silently empties.
    final presenceStale = link == OverallConnection.offline ||
        link == OverallConnection.reconnecting ||
        link == OverallConnection.error;
    final side = touch ? 0.0 : HollowSpacing.sm;

    return list.when(
      loading: () => _LoadingRows(touch: touch),
      error: (_, _) => HollowEmptyState(
        title: "Couldn't load the member list",
        description: 'Reading it from this device failed.',
        action: HollowButton.ghost(
          compact: !touch,
          touch: touch,
          onPressed: () => ref.invalidate(serverMembersProvider(serverId)),
          child: const Text('Try again'),
        ),
      ),
      data: (items) {
        if (items.isEmpty) {
          return const HollowEmptyState(
            title: 'No members yet',
            description: 'They show up here once this server finishes syncing.',
          );
        }
        final lead = presenceStale ? 1 : 0;
        return ListView.builder(
          controller: scrollController,
          padding: EdgeInsets.fromLTRB(
              side, HollowSpacing.sm, side, HollowSpacing.sm + bottomInset),
          itemCount: items.length + lead,
          itemBuilder: (context, index) {
            if (index < lead) return _PresenceNote(touch: touch);
            final item = items[index - lead];
            return switch (item) {
              MemberGroupItem() => _GroupHeader(
                  key: ValueKey('group:${item.label}'),
                  item: item,
                  first: index == lead,
                  touch: touch,
                  onToggle: () => ref
                      .read(collapsedMemberGroupsProvider.notifier)
                      .toggle(serverId, item.label),
                ),
              MemberPersonItem() => _MemberRow(
                  key: ValueKey('member:${item.member.peerId}'),
                  member: item.member,
                  online: item.online,
                  serverId: serverId,
                  touch: touch,
                ),
            };
          },
        );
      },
    );
  }
}

/// A group's title and count; the whole row folds it.
class _GroupHeader extends StatelessWidget {
  final MemberGroupItem item;
  final bool first;
  final bool touch;
  final VoidCallback onToggle;

  const _GroupHeader({
    super.key,
    required this.item,
    required this.first,
    required this.touch,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final side = touch ? HollowSpacing.lg : HollowSpacing.sm;
    return Padding(
      padding: first
          ? EdgeInsets.zero
          : const EdgeInsets.only(top: HollowSpacing.lg),
      child: HollowPressable(
        subtle: true,
        semanticButton: false,
        semanticLabel: item.folded
            ? 'Expand ${item.label}, ${item.count} members'
            : 'Collapse ${item.label}, ${item.count} members',
        onTap: onToggle,
        borderRadius:
            touch ? BorderRadius.zero : BorderRadius.circular(hollow.radiusMd),
        // The header keeps its own bottom gap, so only the top is added here.
        padding: EdgeInsets.fromLTRB(
            side, touch ? HollowSpacing.md : HollowSpacing.sm, side, 0),
        child: HollowSectionHeader(
          item.label,
          count: '${item.count}',
          dense: true,
          action: Icon(
            item.folded ? LucideIcons.chevronRight : LucideIcons.chevronDown,
            size: 14,
            color: hollow.textTertiary,
          ),
        ),
      ),
    );
  }
}

/// One member: the profile card on a tap (the sheet on a phone), the action
/// menu on a right click.
class _MemberRow extends ConsumerWidget {
  final crdt_api.MemberFfi member;
  final bool online;
  final String serverId;
  final bool touch;

  const _MemberRow({
    super.key,
    required this.member,
    required this.online,
    required this.serverId,
    required this.touch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peerId = member.peerId;
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    ref.watch(localNicknameProvider);
    final name = serverDisplayNameFor(
        {peerId: ?profile}, peerId,
        nickname: member.nickname);
    final nickname = member.nickname.isNotEmpty ? member.nickname : null;
    final labels = member.labels.isNotEmpty ? member.labels : null;

    final row = PersonRow(
      peerId: peerId,
      name: name,
      online: online,
      touch: touch,
      nameTrailing: [
        SupportNameGlyph(peerId: peerId, size: touch ? 16 : 14),
        TwitchNameGlyph(peerId: peerId),
      ],
      // Their status line, while it can be current.
      subtitle: online && (profile?.status.isNotEmpty ?? false)
          ? profile!.status
          : null,
      onTap: () => touch
          ? showMobileProfileSheet(context,
              peerId: peerId,
              role: member.role,
              labels: labels,
              serverId: serverId)
          : showProfileCardPopup(
              context: context,
              ref: ref,
              peerId: peerId,
              nickname: nickname,
              role: member.role,
              labels: labels,
              serverId: serverId,
              // Re-read on resize so the card follows the row (issue #54).
              anchorOf: () => memberCardAnchor(context),
            ),
    );
    if (touch) return row;
    return ContextMenuTarget(
      semanticLabel: 'Member actions',
      onOpen: (anchor) => showUserContextMenu(
        context: context,
        ref: ref,
        peerId: peerId,
        serverId: serverId,
        nickname: nickname,
        role: member.role,
        labels: labels,
        anchor: anchor,
      ),
      child: row,
    );
  }
}

/// Where a member row's profile card hangs: to the LEFT of the panel, lifted so
/// a row near the bottom does not open a card that runs off screen.
Offset memberCardAnchor(BuildContext context) {
  final pos = overlayAnchorOf(context);
  return Offset(pos.dx - kProfileCardPopupWidth - 10, pos.dy - 100);
}

class _PresenceNote extends StatelessWidget {
  final bool touch;

  const _PresenceNote({required this.touch});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(touch ? HollowSpacing.lg : HollowSpacing.sm,
          0, touch ? HollowSpacing.lg : HollowSpacing.sm, HollowSpacing.md),
      child: Text(
        "You're offline, so who's online may be out of date.",
        style: (touch ? HollowTypography.bodySmall : HollowTypography.caption)
            .copyWith(color: hollow.textSecondary),
      ),
    );
  }
}

/// Nothing for the first second, then rows at their final geometry.
class _LoadingRows extends StatefulWidget {
  final bool touch;

  const _LoadingRows({required this.touch});

  @override
  State<_LoadingRows> createState() => _LoadingRowsState();
}

class _LoadingRowsState extends State<_LoadingRows> {
  Timer? _timer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final touch = widget.touch;
    final avatar = touch ? 40.0 : 32.0;
    return Semantics(
      label: 'Loading members',
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(
            horizontal: touch ? HollowSpacing.lg : HollowSpacing.md,
            vertical: HollowSpacing.md),
        children: [
          for (var i = 0; i < 6; i++)
            Padding(
              padding: EdgeInsets.symmetric(
                  vertical: touch ? HollowSpacing.sm : HollowSpacing.xxs),
              child: Row(
                children: [
                  HollowSkeleton.circle(avatar),
                  SizedBox(width: touch ? HollowSpacing.md : HollowSpacing.sm),
                  HollowSkeleton(
                      height: HollowSpacing.md, width: 80.0 + (i % 3) * 24),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

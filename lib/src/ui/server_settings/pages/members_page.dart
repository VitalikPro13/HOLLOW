import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/channel_provider.dart'
    show mutedMembersProvider;
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';
import 'package:hollow/src/ui/settings/moderation_dialogs.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Peer ids banned from a server. Invalidated after an unban.
final bannedMembersProvider = FutureProvider.autoDispose
    .family<List<String>, String>((ref, serverId) async {
  try {
    return await crdt_api.getBannedMembers(serverId: serverId);
  } catch (_) {
    return const [];
  }
});

/// The role filter over the member list.
enum MemberFilter { all, admins, moderators, members }

extension on MemberFilter {
  String get label => switch (this) {
        MemberFilter.all => 'All',
        MemberFilter.admins => 'Admins',
        MemberFilter.moderators => 'Moderators',
        MemberFilter.members => 'Members',
      };

  /// The owner counts with the admins.
  bool matches(String role) => switch (this) {
        MemberFilter.all => true,
        MemberFilter.admins => role == 'admin' || role == 'owner',
        MemberFilter.moderators => role == 'moderator',
        MemberFilter.members => role == 'member',
      };
}

const _kRoleOrder = {'owner': 0, 'admin': 1, 'moderator': 2, 'member': 3};

/// "For another 23 hours".
String _remaining(crdt_api.MutedMemberFfi m) {
  if (m.permanent) return 'Until someone unmutes them';
  final left = DateTime.fromMillisecondsSinceEpoch(m.expiresAtMs)
      .difference(DateTime.now());
  if (left.isNegative) return 'About to end';
  String n(int v, String unit) => '$v $unit${v == 1 ? '' : 's'}';
  if (left.inDays >= 1) return 'For another ${n(left.inDays, 'day')}';
  if (left.inHours >= 1) return 'For another ${n(left.inHours, 'hour')}';
  if (left.inMinutes >= 1) return 'For another ${n(left.inMinutes, 'minute')}';
  return 'For less than a minute';
}

String _shortId(String id) =>
    id.length > 12 ? '${id.substring(0, 4)}…${id.substring(id.length - 4)}' : id;

/// Everyone in the server: moderation first for those who can act on it, then
/// one searchable list filtered by role. A big server stays one list, built
/// lazily as it scrolls (a `SettingsSliverPage`).
class MembersPage extends ConsumerStatefulWidget {
  final String serverId;
  const MembersPage({super.key, required this.serverId});

  @override
  ConsumerState<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends ConsumerState<MembersPage> {
  final _search = TextEditingController();
  String _query = '';
  MemberFilter _filter = MemberFilter.all;

  String get _sid => widget.serverId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final membersAsync = ref.watch(serverMembersProvider(_sid));
    final perms = ref.watch(myPermissionsProvider(_sid)).valueOrNull ?? 0;
    final myRole = ref.watch(myRoleProvider(_sid)).valueOrNull ?? 'member';
    final me = ref.watch(identityProvider).peerId;
    final profiles = ref.watch(profileProvider);
    final canModerate = perms & Permission.kickMembers != 0;

    final members = membersAsync.valueOrNull;
    String nameOf(crdt_api.MemberFfi m) =>
        serverDisplayNameFor(profiles, m.peerId, nickname: m.nickname);

    Widget everyone;
    var shown = const <crdt_api.MemberFfi>[];
    if (members == null) {
      everyone = membersAsync.hasError
          ? Text('Could not load the members',
              style: HollowTypography.body.copyWith(color: hollow.error))
          : const Padding(
              padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
              child: Center(child: HollowSpinner.medium()),
            );
    } else {
      final sorted = [...members]..sort((a, b) {
          final r = (_kRoleOrder[a.role] ?? 4).compareTo(_kRoleOrder[b.role] ?? 4);
          if (r != 0) return r;
          final an = nameOf(a), bn = nameOf(b);
          final folded = an.toLowerCase().compareTo(bn.toLowerCase());
          return folded != 0 ? folded : a.peerId.compareTo(b.peerId);
        });
      final q = _query.trim().toLowerCase();
      shown = [
        for (final m in sorted)
          if (_filter.matches(m.role) &&
              (q.isEmpty || nameOf(m).toLowerCase().contains(q)))
            m,
      ];
      int count(MemberFilter f) => members.where((m) => f.matches(m.role)).length;

      final chips = Wrap(
        spacing: HollowSpacing.sm,
        runSpacing: HollowSpacing.sm,
        children: [
          for (final f in MemberFilter.values)
            HollowChip(
              label: f.label,
              hint: '${count(f)}',
              selected: f == _filter,
              onTap: () => setState(() => _filter = f),
            ),
        ],
      );
      final search = HollowTextField(
        controller: _search,
        hintText: 'Find a member',
        isDense: true,
        prefixIcon: Icon(LucideIcons.search, size: 16, color: hollow.textSecondary),
        onChanged: (v) => setState(() => _query = v),
      );

      everyone = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (touch) ...[
            search,
            const SizedBox(height: HollowSpacing.md),
            chips,
          ] else
            Row(
              children: [
                SizedBox(width: 240, child: search),
                const SizedBox(width: HollowSpacing.lg),
                Expanded(child: chips),
              ],
            ),
          const SizedBox(height: HollowSpacing.md),
          if (shown.isEmpty)
            const HollowEmptyState(
              dense: true,
              title: 'Nobody here matches that',
              description: 'Check the spelling, or pick All.',
            ),
        ],
      );
    }

    final indexOf = {for (var i = 0; i < shown.length; i++) shown[i].peerId: i};
    return SettingsSliverPage(
      title: 'Members',
      list: SliverList.builder(
        itemCount: shown.length,
        // A filter or search moves a row to a new index; its key finds it.
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? indexOf[key.value] : null,
        itemBuilder: (context, i) {
          final m = shown[i];
          return _MemberRow(
            key: ValueKey(m.peerId),
            serverId: _sid,
            member: m,
            name: nameOf(m),
            isMe: m.peerId == me,
            canAct: m.peerId != me && canManageRole(myRole, m.role),
            myRole: myRole,
          );
        },
      ),
      children: [
        if (canModerate) _ModerationSection(serverId: _sid),
        SettingsSection(
          title: 'Everyone',
          count: members == null ? null : '${members.length}',
          children: [everyone],
        ),
      ],
    );
  }
}

class _MemberRow extends ConsumerWidget {
  final String serverId;
  final crdt_api.MemberFfi member;
  final String name;
  final bool isMe;
  final bool canAct;
  final String myRole;

  const _MemberRow({
    super.key,
    required this.serverId,
    required this.member,
    required this.name,
    required this.isMe,
    required this.canAct,
    required this.myRole,
  });

  List<({IconData icon, String label, bool danger, VoidCallback onTap})>
      _actions(BuildContext context, WidgetRef ref, {required bool muted}) {
    final peer = member.peerId;
    final roles =
        assignableRoles(myRole).where((r) => r != member.role).toList();
    return [
      for (final r in roles)
        (
          icon: LucideIcons.shield,
          label: 'Make ${roleDisplayName(r).toLowerCase()}',
          danger: false,
          onTap: () => showChangeRoleDialog(context, ref,
              serverId: serverId,
              peerId: peer,
              displayName: name,
              newRole: r,
              currentRole: member.role),
        ),
      (
        icon: LucideIcons.tag,
        label: 'Labels and temporary access',
        danger: false,
        onTap: () =>
            showManageMemberDialog(context, serverId: serverId, peerId: peer),
      ),
      (
        icon: LucideIcons.copy,
        label: 'Copy user ID',
        danger: false,
        onTap: () {
          Clipboard.setData(ClipboardData(text: peer));
          HollowToast.show(context, 'User ID copied');
        },
      ),
      if (muted)
        (
          icon: LucideIcons.volume2,
          label: 'Unmute',
          danger: false,
          onTap: () => unmuteMember(context, ref,
              serverId: serverId, peerId: peer, displayName: name),
        )
      else
        (
          icon: LucideIcons.volumeX,
          label: 'Mute',
          danger: false,
          onTap: () => showMuteMemberDialog(context, ref,
              serverId: serverId, peerId: peer, displayName: name),
        ),
      (
        icon: LucideIcons.userMinus,
        label: 'Kick',
        danger: true,
        onTap: () => showKickMemberDialog(context, ref,
            serverId: serverId, peerId: peer, displayName: name),
      ),
      (
        icon: LucideIcons.ban,
        label: 'Ban',
        danger: true,
        onTap: () => showBanMemberDialog(context, ref,
            serverId: serverId, peerId: peer, displayName: name),
      ),
    ];
  }

  void _menu(BuildContext buttonContext, WidgetRef ref, {required bool muted}) {
    final actions = _actions(buttonContext, ref, muted: muted);
    final roleCount =
        assignableRoles(myRole).where((r) => r != member.role).length;
    showHollowMenu(
      context: buttonContext,
      alignEnd: true,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(buttonContext.size?.width ?? 0,
              buttonContext.size?.height ?? 0)),
      // `_` not `ref`: the menu route's ref dies with the menu, and every row
      // runs after it closes.
      builder: (_, _) => [
        for (var i = 0; i < actions.length; i++) ...[
          if ((i == roleCount && roleCount > 0) || i == actions.length - 3)
            const HollowMenuDivider(),
          HollowMenuItem(
            icon: actions[i].icon,
            label: actions[i].label,
            isDanger: actions[i].danger,
            onTap: actions[i].onTap,
          ),
        ],
      ],
    );
  }

  void _sheet(BuildContext context, WidgetRef ref, {required bool muted}) {
    final hollow = HollowTheme.of(context);
    final actions = _actions(context, ref, muted: muted);
    showHollowSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
                  HollowSpacing.xs, HollowSpacing.lg, HollowSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: HollowTypography.subheading
                          .copyWith(color: hollow.textPrimary)),
                  Text(roleDisplayName(member.role),
                      style: HollowTypography.bodySmall
                          .copyWith(color: hollow.textSecondary)),
                ],
              ),
            ),
            const HollowDivider(),
            // Kick and Ban carry no red here: the confirm they open does.
            for (final a in actions)
              HollowListRow(
                touch: true,
                leading: Icon(a.icon, size: 20, color: hollow.textSecondary),
                title: a.label,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  a.onTap();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final touch = SettingsDensity.touchOf(context);
    final muted = ref
            .watch(mutedMembersProvider(serverId))
            .valueOrNull
            ?.any((m) => m.peerId == member.peerId) ??
        false;
    final labels = member.labels.map((l) => l.name).join(', ');
    final subtitle = muted
        ? 'Muted'
        : '${roleDisplayName(member.role)}${labels.isEmpty ? '' : ' · $labels'}';

    final row = SettingsRow(
      title: name,
      subtitle: subtitle,
      titleTrailing: isMe ? const HollowBadge('You') : null,
      leading: HollowAvatar(peerId: member.peerId, size: 32),
      trailing: canAct
          ? Builder(
              builder: (buttonContext) => HollowIconButton(
                icon: LucideIcons.moreHorizontal,
                label: 'More for $name',
                size: touch ? 44 : 32,
                onPressed: () => touch
                    ? _sheet(context, ref, muted: muted)
                    : _menu(buttonContext, ref, muted: muted),
              ),
            )
          : null,
    );
    if (!touch) return row;
    // A phone opens the person on a tap; the desktop has the member panel.
    return HollowPressable(
      onTap: () => showMobileProfileSheet(context,
          peerId: member.peerId,
          role: member.role,
          labels: member.labels.isNotEmpty ? member.labels : null),
      onLongPress: canAct ? () => _sheet(context, ref, muted: muted) : null,
      subtle: true,
      semanticButton: false,
      child: row,
    );
  }
}

/// Muted and banned people, for whoever can kick and ban.
class _ModerationSection extends ConsumerWidget {
  final String serverId;
  const _ModerationSection({required this.serverId});

  Future<void> _unban(BuildContext context, WidgetRef ref, String peer) async {
    try {
      await crdt_api.unbanMember(serverId: serverId, peerId: peer);
      ref.invalidate(bannedMembersProvider(serverId));
      if (context.mounted) {
        HollowToast.show(context, 'Unbanned', type: HollowToastType.success);
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(
            context, friendlyError(e, fallback: "Couldn't unban. Try again."),
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final muted =
        ref.watch(mutedMembersProvider(serverId)).valueOrNull ?? const [];
    final banned =
        ref.watch(bannedMembersProvider(serverId)).valueOrNull ?? const [];
    final members =
        ref.watch(serverMembersProvider(serverId)).valueOrNull ?? const [];
    final profiles = ref.watch(profileProvider);
    String nameOf(String peer) {
      final m = members.where((m) => m.peerId == peer).firstOrNull;
      return serverDisplayNameFor(profiles, peer, nickname: m?.nickname ?? '');
    }

    String people(int n) => n == 1 ? '1 person' : '$n people';

    return SettingsSection(
      title: 'Moderation',
      children: [
        if (muted.isEmpty)
          const SettingsRow(title: 'Muted', subtitle: 'Nobody is muted')
        else
          SettingsExpandRow(
            title: 'Muted',
            subtitle: "${people(muted.length)} can't post right now",
            children: [
              for (final m in muted)
                SettingsRow(
                  key: ValueKey('muted-${m.peerId}'),
                  title: nameOf(m.peerId),
                  subtitle: _remaining(m),
                  leading: HollowAvatar(peerId: m.peerId, size: 28),
                  trailing: HollowButton.outline(
                    compact: true,
                    semanticLabel: 'Unmute ${nameOf(m.peerId)}',
                    onPressed: () => unmuteMember(context, ref,
                        serverId: serverId,
                        peerId: m.peerId,
                        displayName: nameOf(m.peerId)),
                    child: const Text('Unmute'),
                  ),
                ),
            ],
          ),
        if (banned.isEmpty)
          const SettingsRow(title: 'Banned', subtitle: 'Nobody is banned')
        else
          SettingsExpandRow(
            title: 'Banned',
            subtitle: "${people(banned.length)} can't rejoin",
            children: [
              for (final peer in banned)
                Builder(builder: (context) {
                  final known = profiles.containsKey(peer);
                  return SettingsRow(
                    key: ValueKey('banned-$peer'),
                    title: known ? nameOf(peer) : _shortId(peer),
                    monoTitle: !known,
                    subtitleWidget: known
                        ? Text(_shortId(peer),
                            style: HollowTypography.monoSmall
                                .copyWith(color: hollow.textSecondary))
                        : null,
                    trailing: HollowButton.outline(
                      compact: true,
                      semanticLabel: 'Unban ${known ? nameOf(peer) : 'this person'}',
                      onPressed: () => _unban(context, ref, peer),
                      child: const Text('Unban'),
                    ),
                  );
                }),
            ],
          ),
      ],
    );
  }
}

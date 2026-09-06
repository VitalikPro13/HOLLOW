import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/core/providers/channel_provider.dart'
    show mutedMembersProvider;
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/moderation_dialogs.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Members tab: view members with their roles. Admins and above can change
/// roles and kick.
class MembersTab extends ConsumerWidget {
  final String serverId;

  const MembersTab({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final myRoleAsync = ref.watch(myRoleProvider(serverId));

    return membersAsync.when(
      data: (members) {
        if (members.isEmpty) {
          return Center(
            child: Text(
              'No members',
              style:
                  HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
          );
        }

        final sorted = [...members]..sort((a, b) {
            const order = {
              'owner': 0,
              'admin': 1,
              'moderator': 2,
              'member': 3,
            };
            return (order[a.role] ?? 4).compareTo(order[b.role] ?? 4);
          });

        final myRole = myRoleAsync.valueOrNull ?? 'member';
        final canKick = myRole == 'owner' || myRole == 'admin';

        return ListView(
          padding: const EdgeInsets.all(HollowSpacing.lg),
          children: [
            for (final member in sorted)
              _MemberRow(
                serverId: serverId,
                displayName: member.displayName,
                peerId: member.peerId,
                role: member.role,
                nickname: member.nickname,
                myRole: myRole,
              ),
            if (canKick) ...[
              _MutedMembersSection(serverId: serverId),
              _BannedMembersSection(serverId: serverId),
            ],
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          'Failed to load members: $e',
          style: HollowTypography.body.copyWith(color: hollow.error),
        ),
      ),
    );
  }
}

/// The colour and icon a role is drawn with.
({Color color, IconData icon}) _roleInfo(String role, HollowTheme hollow) {
  return switch (role) {
    'owner' => (color: hollow.warning, icon: LucideIcons.crown),
    'admin' => (color: const Color(0xFFA78BFA), icon: LucideIcons.shield),
    'moderator' => (
      color: Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning,
      icon: LucideIcons.shieldCheck,
    ),
    _ => (color: hollow.textSecondary, icon: LucideIcons.user),
  };
}

// The role hierarchy helpers live in core/role_hierarchy.dart so the
// profile-card Manage Member dialog cannot drift from this tab.

class _MemberRow extends ConsumerWidget {
  final String serverId;
  final String displayName;
  final String peerId;
  final String role;
  final String nickname;
  final String myRole;

  const _MemberRow({
    required this.serverId,
    required this.displayName,
    required this.peerId,
    required this.role,
    required this.nickname,
    required this.myRole,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final localPeerId = ref.watch(identityProvider).peerId;
    final isMe = peerId == localPeerId;
    final info = _roleInfo(role, hollow);
    final canManage = !isMe && canManageRole(myRole, role);
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[peerId]));
    final resolvedName =
        serverDisplayNameForPeer(peerProfile, peerId, nickname: nickname);

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
        ),
        child: Row(
          children: [
            HollowAvatar(peerId: peerId, size: 32),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          resolvedName,
                          style: HollowTypography.body
                              .copyWith(color: hollow.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: HollowSpacing.xs),
                        Text(
                          '(you)',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    peerId,
                    style: HollowTypography.caption,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: info.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(HollowRadius.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(info.icon, size: 12, color: info.color),
                  const SizedBox(width: HollowSpacing.xs),
                  Text(
                    role[0].toUpperCase() + role.substring(1),
                    style: HollowTypography.caption.copyWith(
                      color: info.color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            // The same `showHollowMenu` surface as every other context menu
            // (issue #61) rather than a Material PopupMenuButton, on the same
            // shared confirms the mobile route and the desktop user menu use.
            if (canManage) ...[
              const SizedBox(width: HollowSpacing.xs),
              // Builder so the menu anchors off the BUTTON rather than the
              // 600px row.
              Builder(
                builder: (buttonContext) => HollowTooltip(
                  message: 'Member actions',
                  child: HollowPressable(
                    semanticLabel: 'Member actions',
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    onTap: () => _showActions(buttonContext, ref),
                    child: Icon(
                      LucideIcons.moreVertical,
                      size: 16,
                      color: hollow.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The member action menu: role changes, then the moderation trio.
  void _showActions(BuildContext context, WidgetRef ref) {
    final assignable =
        assignableRoles(myRole).where((r) => r != role).toList();
    showHollowMenu(
      context: context,
      anchor: overlayAnchorOf(context),
      // `_` not `ref`: the menu route's ref dies with the menu, and every row
      // here runs after it closes (test/menu_builder_ref_guard_test.dart).
      builder: (menuContext, _) => <HollowMenuEntry>[
        for (final r in assignable)
          HollowMenuItem(
            icon: _roleInfo(r, HollowTheme.of(menuContext)).icon,
            label: 'Make ${r[0].toUpperCase()}${r.substring(1)}',
            onTap: () => showChangeRoleDialog(context, ref,
                serverId: serverId,
                peerId: peerId,
                displayName: displayName,
                newRole: r),
          ),
        if (assignable.isNotEmpty) const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.volumeX,
          label: 'Mute member',
          onTap: () => showMuteMemberDialog(context, ref,
              serverId: serverId, peerId: peerId, displayName: displayName),
        ),
        HollowMenuItem(
          icon: LucideIcons.userMinus,
          label: 'Kick member',
          isDanger: true,
          onTap: () => showKickMemberDialog(context, ref,
              serverId: serverId, peerId: peerId, displayName: displayName),
        ),
        HollowMenuItem(
          icon: LucideIcons.ban,
          label: 'Ban member',
          isDanger: true,
          onTap: () => showBanMemberDialog(context, ref,
              serverId: serverId, peerId: peerId, displayName: displayName),
        ),
      ],
    );
  }
}

class _MutedMembersSection extends ConsumerStatefulWidget {
  final String serverId;

  const _MutedMembersSection({required this.serverId});

  @override
  ConsumerState<_MutedMembersSection> createState() =>
      _MutedMembersSectionState();
}

class _MutedMembersSectionState extends ConsumerState<_MutedMembersSection> {
  bool _expanded = false;

  Future<void> _unmute(String peerId) async {
    try {
      await crdt_api.unmuteMember(serverId: widget.serverId, peerId: peerId);
      ref.invalidate(mutedMembersProvider(widget.serverId));
      if (mounted) {
        HollowToast.show(context, 'Member unmuted',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to unmute: $e',
            type: HollowToastType.error);
      }
    }
  }

  String _muteLabel(crdt_api.MutedMemberFfi m) {
    if (m.permanent) return 'Permanent';
    final remaining = DateTime.fromMillisecondsSinceEpoch(m.expiresAtMs)
        .difference(DateTime.now());
    if (remaining.isNegative) return 'Expired';
    return '${formatMuteRemaining(remaining)} left';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Provider-backed rather than a one-shot load, so the section appears the
    // moment a mute lands.
    final muted =
        ref.watch(mutedMembersProvider(widget.serverId)).valueOrNull ?? const [];
    if (muted.isEmpty) return const SizedBox.shrink();
    // Muted members are still members, so their display names resolve.
    final members =
        ref.watch(serverMembersProvider(widget.serverId)).valueOrNull ?? const [];
    String nameFor(String peerId) {
      for (final m in members) {
        if (m.peerId == peerId) {
          return m.nickname.isNotEmpty ? m.nickname : m.displayName;
        }
      }
      return peerId.length > 12 ? '${peerId.substring(0, 12)}…' : peerId;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: HollowSpacing.lg),
        HollowPressable(
          onTap: () => setState(() => _expanded = !_expanded),
          subtle: true,
          semanticButton: false,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
          child: Row(
            children: [
              Icon(
                _expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 14,
                color: hollow.textSecondary,
              ),
              const SizedBox(width: HollowSpacing.xs),
              Icon(LucideIcons.volumeX, size: 14, color: hollow.warning),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'Muted (${muted.length})',
                style: HollowTypography.label.copyWith(
                  color: hollow.warning,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: HollowSpacing.sm),
          for (final m in muted)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md,
                  vertical: HollowSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                ),
                child: Row(
                  children: [
                    HollowAvatar(peerId: m.peerId, size: 28),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            nameFor(m.peerId),
                            style: HollowTypography.bodySmall.copyWith(
                              color: hollow.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            _muteLabel(m),
                            style: HollowTypography.caption.copyWith(
                              color: hollow.warning,
                            ),
                          ),
                        ],
                      ),
                    ),
                    HollowButton.ghost(
                      compact: true,
                      onPressed: () => _unmute(m.peerId),
                      child: Text(
                        'Unmute',
                        style: HollowTypography.bodySmall.copyWith(
                          color: hollow.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _BannedMembersSection extends ConsumerStatefulWidget {
  final String serverId;

  const _BannedMembersSection({required this.serverId});

  @override
  ConsumerState<_BannedMembersSection> createState() =>
      _BannedMembersSectionState();
}

class _BannedMembersSectionState extends ConsumerState<_BannedMembersSection> {
  List<String>? _banned;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _loadBanned();
  }

  Future<void> _loadBanned() async {
    try {
      final list = await crdt_api.getBannedMembers(serverId: widget.serverId);
      if (mounted) setState(() => _banned = list);
    } catch (_) {
      if (mounted) setState(() => _banned = []);
    }
  }

  Future<void> _unban(String peerId) async {
    try {
      await crdt_api.unbanMember(serverId: widget.serverId, peerId: peerId);
      if (mounted) {
        HollowToast.show(context, 'Member unbanned', type: HollowToastType.success);
        _loadBanned();
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to unban: $e', type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final banned = _banned;
    if (banned == null || banned.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: HollowSpacing.lg),
        HollowPressable(
          onTap: () => setState(() => _expanded = !_expanded),
          subtle: true,
          semanticButton: false,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
          child: Row(
            children: [
              Icon(
                _expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 14,
                color: hollow.textSecondary,
              ),
              const SizedBox(width: HollowSpacing.xs),
              Icon(LucideIcons.ban, size: 14, color: hollow.error),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'Banned (${banned.length})',
                style: HollowTypography.label.copyWith(
                  color: hollow.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: HollowSpacing.sm),
          for (final peerId in banned)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md,
                  vertical: HollowSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        peerId,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    HollowButton.ghost(
                      compact: true,
                      onPressed: () => _unban(peerId),
                      child: Text(
                        'Unban',
                        style: HollowTypography.bodySmall.copyWith(
                          color: hollow.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}

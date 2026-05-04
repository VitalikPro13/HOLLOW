import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Members tab — view members with their roles. Admins+ can change roles & kick.
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

        // Sort: owner first, then admin, then moderator, then member
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
            if (canKick)
              _BannedMembersSection(serverId: serverId),
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

/// Returns role display info: color, icon.
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

/// Whether [actorRole] can change [targetRole] to a different role.
bool _canManageRole(String actorRole, String targetRole) {
  const priorities = {'owner': 3, 'admin': 2, 'moderator': 1, 'member': 0};
  final actorPriority = priorities[actorRole] ?? 0;
  final targetPriority = priorities[targetRole] ?? 0;
  if (actorRole == 'owner') return true;
  if (actorPriority <= 1) return false; // Members & moderators can't manage
  return actorPriority > targetPriority;
}

/// Roles that [actorRole] can assign (must be below actor's rank).
List<String> _assignableRoles(String actorRole) {
  if (actorRole == 'owner') {
    return ['admin', 'moderator', 'member'];
  }
  if (actorRole == 'admin') {
    return ['moderator', 'member'];
  }
  return [];
}

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
    final canManage = !isMe && _canManageRole(myRole, role);
    final profiles = ref.watch(profileProvider);
    final resolvedName =
        serverDisplayNameFor(profiles, peerId, nickname: nickname);

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
            // Role badge
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
            // Action menu (only visible if we can manage this member)
            if (canManage) ...[
              const SizedBox(width: HollowSpacing.xs),
              PopupMenuButton<String>(
                icon: Icon(
                  LucideIcons.moreVertical,
                  size: 16,
                  color: hollow.textSecondary,
                ),
                color: hollow.elevated,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  side: BorderSide(color: hollow.border),
                ),
                itemBuilder: (context) {
                  final assignable = _assignableRoles(myRole);
                  return [
                    // Role change options
                    for (final r in assignable)
                      if (r != role)
                        PopupMenuItem(
                          value: 'role:$r',
                          child: Row(
                            children: [
                              Icon(
                                _roleInfo(r, hollow).icon,
                                size: 14,
                                color: _roleInfo(r, hollow).color,
                              ),
                              const SizedBox(width: HollowSpacing.sm),
                              Text(
                                'Make ${r[0].toUpperCase()}${r.substring(1)}',
                                style: HollowTypography.body.copyWith(
                                  color: hollow.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                    // Divider + Kick
                    if (assignable.isNotEmpty)
                      const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'kick',
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.userMinus,
                            size: 14,
                            color: hollow.error,
                          ),
                          const SizedBox(width: HollowSpacing.sm),
                          Text(
                            'Kick Member',
                            style: HollowTypography.body.copyWith(
                              color: hollow.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'ban',
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.ban,
                            size: 14,
                            color: hollow.error,
                          ),
                          const SizedBox(width: HollowSpacing.sm),
                          Text(
                            'Ban Member',
                            style: HollowTypography.body.copyWith(
                              color: hollow.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ];
                },
                onSelected: (value) {
                  if (value.startsWith('role:')) {
                    final newRole = value.substring(5);
                    _changeRole(context, ref, newRole);
                  } else if (value == 'kick') {
                    _confirmKick(context, ref);
                  } else if (value == 'ban') {
                    _confirmBan(context, ref);
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _changeRole(BuildContext context, WidgetRef ref, String newRole) {
    final roleName = newRole[0].toUpperCase() + newRole.substring(1);
    showHollowDialog(
      context: context,
      builder: (context) => _ConfirmDialog(
        title: 'Change Role',
        message:
            'Change $displayName\'s role to $roleName?',
        confirmLabel: 'Change',
        onConfirm: () async {
          Navigator.of(context).pop();
          try {
            await crdt_api.changeMemberRole(
              serverId: serverId,
              peerId: peerId,
              newRole: newRole,
            );
            if (context.mounted) {
              HollowToast.show(
                context,
                '$displayName is now $roleName',
                type: HollowToastType.success,
              );
            }
          } catch (e) {
            if (context.mounted) {
              HollowToast.show(
                context,
                'Failed to change role: $e',
                type: HollowToastType.error,
              );
            }
          }
        },
      ),
    );
  }

  void _confirmKick(BuildContext context, WidgetRef ref) {
    showHollowDialog(
      context: context,
      builder: (context) => _ConfirmDialog(
        title: 'Kick Member',
        message:
            'Are you sure you want to kick $displayName from the server?',
        confirmLabel: 'Kick',
        isDanger: true,
        onConfirm: () async {
          Navigator.of(context).pop();
          try {
            await crdt_api.kickMember(
              serverId: serverId,
              peerId: peerId,
            );
            if (context.mounted) {
              HollowToast.show(
                context,
                '$displayName has been kicked',
                type: HollowToastType.success,
              );
            }
          } catch (e) {
            if (context.mounted) {
              HollowToast.show(
                context,
                'Failed to kick member: $e',
                type: HollowToastType.error,
              );
            }
          }
        },
      ),
    );
  }

  void _confirmBan(BuildContext context, WidgetRef ref) {
    showHollowDialog(
      context: context,
      builder: (context) => _ConfirmDialog(
        title: 'Ban Member',
        message:
            'Are you sure you want to ban $displayName? They will be removed and unable to rejoin.',
        confirmLabel: 'Ban',
        isDanger: true,
        onConfirm: () async {
          Navigator.of(context).pop();
          try {
            await crdt_api.banMember(
              serverId: serverId,
              peerId: peerId,
            );
            if (context.mounted) {
              HollowToast.show(
                context,
                '$displayName has been banned',
                type: HollowToastType.success,
              );
            }
          } catch (e) {
            if (context.mounted) {
              HollowToast.show(
                context,
                'Failed to ban member: $e',
                type: HollowToastType.error,
              );
            }
          }
        },
      ),
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
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
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

class _ConfirmDialog extends StatelessWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final bool isDanger;
  final VoidCallback onConfirm;

  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.isDanger = false,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(HollowSpacing.lg),
          decoration: BoxDecoration(
            color: hollow.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.accent.withValues(alpha: 0.2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: HollowTypography.heading
                  .copyWith(color: hollow.textPrimary, fontSize: 18),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              message,
              style: HollowTypography.body.copyWith(color: hollow.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: HollowButton.ghost(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: isDanger
                      ? HollowButton.danger(
                          onPressed: onConfirm,
                          child: Text(confirmLabel),
                        )
                      : HollowButton.filled(
                          onPressed: onConfirm,
                          child: Text(confirmLabel),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }
}

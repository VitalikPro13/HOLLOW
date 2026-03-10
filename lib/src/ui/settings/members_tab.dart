import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/rust/api/crdt.dart' as crdt_api;
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Members tab — view members with their roles. Admins+ can change roles & kick.
class MembersTab extends ConsumerWidget {
  final String serverId;

  const MembersTab({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final myRoleAsync = ref.watch(myRoleProvider(serverId));

    return membersAsync.when(
      data: (members) {
        if (members.isEmpty) {
          return Center(
            child: Text(
              'No members',
              style:
                  HavenTypography.body.copyWith(color: haven.textSecondary),
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

        return ListView.builder(
          padding: const EdgeInsets.all(HavenSpacing.lg),
          itemCount: sorted.length,
          itemBuilder: (context, index) {
            final member = sorted[index];
            return _MemberRow(
              serverId: serverId,
              displayName: member.displayName,
              peerId: member.peerId,
              role: member.role,
              nickname: member.nickname,
              myRole: myRole,
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          'Failed to load members: $e',
          style: HavenTypography.body.copyWith(color: haven.error),
        ),
      ),
    );
  }
}

/// Returns role display info: color, icon.
({Color color, IconData icon}) _roleInfo(String role, HavenTheme haven) {
  return switch (role) {
    'owner' => (color: haven.warning, icon: LucideIcons.crown),
    'admin' => (color: const Color(0xFFA78BFA), icon: LucideIcons.shield),
    'moderator' => (
      color: Color.lerp(haven.warning, haven.error, 0.5) ?? haven.warning,
      icon: LucideIcons.shieldCheck,
    ),
    _ => (color: haven.textSecondary, icon: LucideIcons.user),
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
    final haven = HavenTheme.of(context);
    final localPeerId = ref.watch(identityProvider).peerId;
    final isMe = peerId == localPeerId;
    final info = _roleInfo(role, haven);
    final canManage = !isMe && _canManageRole(myRole, role);
    final profiles = ref.watch(profileProvider);
    final resolvedName =
        serverDisplayNameFor(profiles, peerId, nickname: nickname);

    return Padding(
      padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.md,
          vertical: HavenSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: haven.elevated,
          borderRadius: BorderRadius.circular(haven.radiusMd),
        ),
        child: Row(
          children: [
            HavenAvatar(peerId: peerId, size: 32),
            const SizedBox(width: HavenSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          resolvedName,
                          style: HavenTypography.body
                              .copyWith(color: haven.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: HavenSpacing.xs),
                        Text(
                          '(you)',
                          style: HavenTypography.caption.copyWith(
                            color: haven.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    peerId,
                    style: HavenTypography.caption,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: HavenSpacing.sm),
            // Role badge
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HavenSpacing.sm,
                vertical: HavenSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: info.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(HavenRadius.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(info.icon, size: 12, color: info.color),
                  const SizedBox(width: HavenSpacing.xs),
                  Text(
                    role[0].toUpperCase() + role.substring(1),
                    style: HavenTypography.caption.copyWith(
                      color: info.color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            // Action menu (only visible if we can manage this member)
            if (canManage) ...[
              const SizedBox(width: HavenSpacing.xs),
              PopupMenuButton<String>(
                icon: Icon(
                  LucideIcons.moreVertical,
                  size: 16,
                  color: haven.textSecondary,
                ),
                color: haven.elevated,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(haven.radiusMd),
                  side: BorderSide(color: haven.border),
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
                                _roleInfo(r, haven).icon,
                                size: 14,
                                color: _roleInfo(r, haven).color,
                              ),
                              const SizedBox(width: HavenSpacing.sm),
                              Text(
                                'Make ${r[0].toUpperCase()}${r.substring(1)}',
                                style: HavenTypography.body.copyWith(
                                  color: haven.textPrimary,
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
                            color: haven.error,
                          ),
                          const SizedBox(width: HavenSpacing.sm),
                          Text(
                            'Kick Member',
                            style: HavenTypography.body.copyWith(
                              color: haven.error,
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
    showHavenDialog(
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
              HavenToast.show(
                context,
                '$displayName is now $roleName',
                type: HavenToastType.success,
              );
            }
          } catch (e) {
            if (context.mounted) {
              HavenToast.show(
                context,
                'Failed to change role: $e',
                type: HavenToastType.error,
              );
            }
          }
        },
      ),
    );
  }

  void _confirmKick(BuildContext context, WidgetRef ref) {
    showHavenDialog(
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
              HavenToast.show(
                context,
                '$displayName has been kicked',
                type: HavenToastType.success,
              );
            }
          } catch (e) {
            if (context.mounted) {
              HavenToast.show(
                context,
                'Failed to kick member: $e',
                type: HavenToastType.error,
              );
            }
          }
        },
      ),
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
    final haven = HavenTheme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 360,
          padding: const EdgeInsets.all(HavenSpacing.lg),
          decoration: BoxDecoration(
            color: haven.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(haven.radiusLg),
            border: Border.all(color: haven.accent.withValues(alpha: 0.2)),
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
              style: HavenTypography.heading
                  .copyWith(color: haven.textPrimary, fontSize: 18),
            ),
            const SizedBox(height: HavenSpacing.md),
            Text(
              message,
              style: HavenTypography.body.copyWith(color: haven.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HavenSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: HavenButton.ghost(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: HavenSpacing.md),
                Expanded(
                  child: isDanger
                      ? HavenButton.danger(
                          onPressed: onConfirm,
                          child: Text(confirmLabel),
                        )
                      : HavenButton.filled(
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

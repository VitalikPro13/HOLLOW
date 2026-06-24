import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileRolesRoute extends ConsumerStatefulWidget {
  final String serverId;

  const MobileRolesRoute({super.key, required this.serverId});

  @override
  ConsumerState<MobileRolesRoute> createState() => _MobileRolesRouteState();
}

class _MobileRolesRouteState extends ConsumerState<MobileRolesRoute> {
  final Map<String, int> _perms = {};
  bool _loading = true;

  static const _roles = ['admin', 'moderator', 'member'];

  static const _defaultPerms = {
    'admin': Permission.manageChannels | Permission.manageRoles |
        Permission.kickMembers | Permission.sendMessages | Permission.readMessages,
    'moderator': Permission.kickMembers | Permission.sendMessages | Permission.readMessages,
    'member': Permission.sendMessages | Permission.readMessages,
  };

  static const _permEntries = [
    (Permission.manageServer, 'Manage Server', LucideIcons.settings),
    (Permission.manageChannels, 'Manage Channels', LucideIcons.hash),
    (Permission.manageRoles, 'Manage Roles', LucideIcons.shieldCheck),
    (Permission.kickMembers, 'Kick / Ban Members', LucideIcons.userMinus),
    (Permission.sendMessages, 'Send Messages', LucideIcons.messageSquare),
    (Permission.readMessages, 'Read Messages', LucideIcons.eye),
  ];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    for (final role in _roles) {
      try {
        final p = await crdt_api.getRolePermissions(
          serverId: widget.serverId, role: role,
        );
        _perms[role] = p;
      } catch (_) {
        _perms[role] = _defaultPerms[role] ?? 0;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _togglePerm(String role, int bit) async {
    final current = _perms[role] ?? 0;
    final newPerms = current ^ bit;
    setState(() => _perms[role] = newPerms);
    try {
      await crdt_api.changeRolePermissions(
        serverId: widget.serverId, role: role, permissions: newPerms,
      );
    } catch (e) {
      setState(() => _perms[role] = current);
      if (mounted) {
        HollowToast.show(context, 'Failed to update', type: HollowToastType.error);
      }
    }
  }

  Future<void> _resetRole(String role) async {
    final def = _defaultPerms[role] ?? 0;
    setState(() => _perms[role] = def);
    try {
      await crdt_api.changeRolePermissions(
        serverId: widget.serverId, role: role, permissions: def,
      );
      if (mounted) {
        HollowToast.show(context, 'Permissions reset', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to reset', type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final myRole = ref.watch(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: hollow.surface,
                border: Border(bottom: BorderSide(color: hollow.border)),
              ),
              child: Row(
                children: [
                  HollowPressable(
                    onTap: () => Navigator.pop(context),
                    semanticLabel: 'Back',
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(LucideIcons.arrowLeft, size: 22, color: hollow.textPrimary),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Text('Roles', style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                  )),
                ],
              ),
            ),

            // Content
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.all(HollowSpacing.lg),
                      children: [
                        for (final role in _roles) ...[
                          _RoleSection(
                            role: role,
                            perms: _perms[role] ?? 0,
                            canEdit: _canEditRole(myRole, role),
                            onToggle: (bit) => _togglePerm(role, bit),
                            onReset: () => _resetRole(role),
                          ),
                          const SizedBox(height: HollowSpacing.xl),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  bool _canEditRole(String myRole, String targetRole) {
    if (myRole == 'owner') return true;
    if (myRole == 'admin' && targetRole != 'admin') return true;
    return false;
  }
}

Color _roleColor(String role) {
  switch (role) {
    case 'admin': return const Color(0xFFA78BFA);
    case 'moderator': return const Color(0xFFFF9800);
    default: return const Color(0xFF78909C);
  }
}

IconData _roleIcon(String role) {
  switch (role) {
    case 'admin': return LucideIcons.shieldCheck;
    case 'moderator': return LucideIcons.shield;
    default: return LucideIcons.user;
  }
}

class _RoleSection extends StatelessWidget {
  final String role;
  final int perms;
  final bool canEdit;
  final void Function(int bit) onToggle;
  final VoidCallback onReset;

  const _RoleSection({
    required this.role,
    required this.perms,
    required this.canEdit,
    required this.onToggle,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = _roleColor(role);

    return Container(
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Role header
          Container(
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.08),
              borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusMd)),
            ),
            child: Row(
              children: [
                Icon(_roleIcon(role), size: 18, color: color),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  role[0].toUpperCase() + role.substring(1),
                  style: HollowTypography.body.copyWith(
                    color: color, fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (canEdit)
                  HollowPressable(
                    onTap: onReset,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Text('Reset', style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    )),
                  ),
              ],
            ),
          ),

          // Permission toggles
          for (final entry in _MobileRolesRouteState._permEntries)
            _PermissionRow(
              bit: entry.$1,
              label: entry.$2,
              icon: entry.$3,
              enabled: (perms & entry.$1) != 0,
              canEdit: canEdit,
              onToggle: () => onToggle(entry.$1),
            ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final int bit;
  final String label;
  final IconData icon;
  final bool enabled;
  final bool canEdit;
  final VoidCallback onToggle;

  const _PermissionRow({
    required this.bit,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.canEdit,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: canEdit ? onToggle : null,
      subtle: true,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md, vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Text(label, style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
            )),
          ),
          AnimatedOpacity(
            opacity: canEdit ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: Switch(
              value: enabled,
              onChanged: canEdit ? (_) => onToggle() : null,
              activeTrackColor: hollow.accent,
              activeThumbColor: Colors.white,
              inactiveTrackColor: hollow.border,
            ),
          ),
        ],
      ),
    );
  }
}

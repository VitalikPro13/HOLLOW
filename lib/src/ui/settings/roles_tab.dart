import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Permission descriptions for toggle display.
const _permissionEntries = <({String label, String desc, int bit})>[
  (label: 'Manage Server', desc: 'Server settings, profile, and deletion', bit: Permission.manageServer),
  (label: 'Manage Channels', desc: 'Create, edit, and delete channels', bit: Permission.manageChannels),
  (label: 'Manage Roles', desc: 'Change member roles and labels', bit: Permission.manageRoles),
  (label: 'Kick Members', desc: 'Remove or ban members', bit: Permission.kickMembers),
  (label: 'Send Messages', desc: 'Send messages in channels', bit: Permission.sendMessages),
  (label: 'Read Messages', desc: 'View messages in channels', bit: Permission.readMessages),
  (label: 'Manage Emotes', desc: 'Add and remove custom server emotes', bit: Permission.manageEmotes),
];

/// Role colors matching the member panel.
const _roleColors = <String, ({Color color, IconData icon})>{
  'admin': (color: Color(0xFFAB47BC), icon: LucideIcons.shieldCheck),
  'moderator': (color: Color(0xFFFF9800), icon: LucideIcons.shield),
  'member': (color: Color(0xFF78909C), icon: LucideIcons.user),
};

/// Roles tab — Owner-only. Toggle permissions for Admin, Moderator, Member.
class RolesTab extends ConsumerStatefulWidget {
  final String serverId;

  const RolesTab({super.key, required this.serverId});

  @override
  ConsumerState<RolesTab> createState() => _RolesTabState();
}

class _RolesTabState extends ConsumerState<RolesTab> {
  final Map<String, int> _perms = {};
  // Rust MemberRole::default_permissions via FFI — never a hand-written
  // mirror: a stale copy here once froze Admin without MANAGE_SERVER into
  // servers' role_permissions overrides via Reset.
  final Map<String, int> _defaults = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    for (final role in ['admin', 'moderator', 'member']) {
      _defaults[role] = crdt_api.defaultRolePermissions(role: role);
    }
    try {
      for (final role in ['admin', 'moderator', 'member']) {
        final p = await crdt_api.getRolePermissions(
          serverId: widget.serverId,
          role: role,
        );
        _perms[role] = p;
      }
    } catch (e) {
      // Fall back to defaults
      for (final role in ['admin', 'moderator', 'member']) {
        _perms[role] = _defaults[role]!;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _togglePermission(String role, int bit, bool enabled) async {
    final current = _perms[role] ?? _defaults[role] ?? 0;
    final updated = enabled ? (current | bit) : (current & ~bit);
    setState(() => _perms[role] = updated);
    try {
      await crdt_api.changeRolePermissions(
        serverId: widget.serverId,
        role: role,
        permissions: updated,
      );
    } catch (e) {
      setState(() => _perms[role] = current);
      if (mounted) {
        HollowToast.show(
          context,
          'Failed to update permissions: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  Future<void> _resetToDefault(String role) async {
    final defaultPerm = _defaults[role];
    if (defaultPerm == null) return;
    final previous = _perms[role] ?? defaultPerm;
    setState(() => _perms[role] = defaultPerm);
    try {
      await crdt_api.changeRolePermissions(
        serverId: widget.serverId,
        role: role,
        permissions: defaultPerm,
      );
      if (mounted) {
        HollowToast.show(
          context,
          '${role[0].toUpperCase()}${role.substring(1)} permissions reset to defaults',
          type: HollowToastType.success,
        );
      }
    } catch (e) {
      setState(() => _perms[role] = previous);
      if (mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final myRole =
        ref.watch(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';
    const rolePriority = {'owner': 3, 'admin': 2, 'moderator': 1, 'member': 0};
    final myPriority = rolePriority[myRole] ?? 0;

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      children: [
        for (final role in ['admin', 'moderator', 'member']) ...[
          _buildRoleSection(role, hollow, myPriority > (rolePriority[role] ?? 0)),
          const SizedBox(height: HollowSpacing.xl),
        ],
      ],
    );
  }

  Widget _buildRoleSection(String role, HollowTheme hollow, bool canEdit) {
    final info = _roleColors[role]!;
    final perms = _perms[role] ?? _defaults[role] ?? 0;
    final displayName = role[0].toUpperCase() + role.substring(1);

    return Container(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(info.icon, size: 18, color: info.color),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                displayName,
                style: HollowTypography.subheading.copyWith(
                  color: info.color,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (canEdit) HollowButton.ghost(
                compact: true,
                onPressed: () => _resetToDefault(role),
                child: Text(
                  'Reset',
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),

          // Permission toggles
          for (final entry in _permissionEntries) ...[
            _PermissionRow(
              label: entry.label,
              description: entry.desc,
              enabled: (perms & entry.bit) != 0,
              onChanged: canEdit
                  ? (v) => _togglePermission(role, entry.bit, v)
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final String label;
  final String description;
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  const _PermissionRow({
    required this.label,
    required this.description,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                  ),
                ),
                Text(
                  description,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          HollowToggle(
            value: enabled,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

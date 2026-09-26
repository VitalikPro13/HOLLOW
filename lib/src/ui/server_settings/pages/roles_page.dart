import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

const _kRoles = ['admin', 'moderator', 'member'];

const _kRolePriority = {'owner': 3, 'admin': 2, 'moderator': 1, 'member': 0};

const _kPermissionRows = <({String title, String subtitle, int bit})>[
  (
    title: 'Manage the server',
    subtitle: 'Settings and profile',
    bit: Permission.manageServer
  ),
  (
    title: 'Manage channels',
    subtitle: 'Create, edit and delete channels',
    bit: Permission.manageChannels
  ),
  (
    title: 'Manage roles',
    subtitle: 'Change member roles and labels',
    bit: Permission.manageRoles
  ),
  (
    title: 'Kick and ban',
    subtitle: 'Remove members, or keep them out',
    bit: Permission.kickMembers
  ),
  (
    title: 'Send messages',
    subtitle: 'Post in channels',
    bit: Permission.sendMessages
  ),
  (
    title: 'Read messages',
    subtitle: 'See messages in channels',
    bit: Permission.readMessages
  ),
  (
    title: 'Manage emotes',
    subtitle: 'Add and remove server emotes and stickers',
    bit: Permission.manageEmotes
  ),
];

/// Each role's permission bits and Rust's defaults for it. The defaults come
/// through the FFI, never a Dart copy: a stale copy once froze Admin without
/// MANAGE_SERVER into servers on Reset.
final rolePermissionsProvider = FutureProvider.autoDispose
    .family<Map<String, ({int perms, int defaults})>, String>(
        (ref, serverId) async {
  final out = <String, ({int perms, int defaults})>{};
  for (final role in _kRoles) {
    // A failed read errors the page instead of falling back to the defaults:
    // shown as real, one tap on a toggle would overwrite the stored bits.
    final defaults = crdt_api.defaultRolePermissions(role: role);
    final perms =
        await crdt_api.getRolePermissions(serverId: serverId, role: role);
    out[role] = (perms: perms, defaults: defaults);
  }
  return out;
});

/// Who may do what: one table, a column per role. A role above yours shows its
/// column but you cannot change it; Rust enforces the same rule.
class RolesPage extends ConsumerStatefulWidget {
  final String serverId;
  const RolesPage({super.key, required this.serverId});

  @override
  ConsumerState<RolesPage> createState() => _RolesPageState();
}

class _RolesPageState extends ConsumerState<RolesPage> {
  /// Optimistic values over the loaded ones: a re-read right after a write
  /// returns the previous bits.
  final Map<String, int> _local = {};

  String get _sid => widget.serverId;

  Future<void> _write(String role, int perms, int before) async {
    setState(() => _local[role] = perms);
    try {
      await crdt_api.changeRolePermissions(
          serverId: _sid, role: role, permissions: perms);
    } catch (e) {
      if (!mounted) return;
      setState(() => _local[role] = before);
      HollowToast.show(
          context,
          friendlyError(e, fallback: "Couldn't change that. Try again."),
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final myRole = ref.watch(myRoleProvider(_sid)).valueOrNull ?? 'member';
    final myPriority = _kRolePriority[myRole] ?? 0;
    final loaded = ref.watch(rolePermissionsProvider(_sid));
    final data = loaded.valueOrNull;

    bool canEdit(String role) => myPriority > (_kRolePriority[role] ?? 0);
    int perms(String role) => _local[role] ?? data?[role]?.perms ?? 0;
    final editable = _kRoles.where(canEdit).toList();
    final atDefaults = data != null &&
        _kRoles.every((r) => perms(r) == data[r]!.defaults);

    final intro = myRole == 'owner'
        ? "You're the owner, so you can do everything. Each role can do "
            "what's switched on in its column."
        : "You can change the roles below yours. Each role can do what's "
            "switched on in its column.";

    final column = touch ? 64.0 : 96.0;
    Widget header(String text) => SizedBox(
          width: column,
          child: Text(text,
              textAlign: TextAlign.center,
              style:
                  HollowTypography.label.copyWith(color: hollow.textSecondary)),
        );

    if (data == null) {
      return SettingsPage(
        title: 'Roles',
        intro: intro,
        children: [
          if (loaded.hasError)
            SettingsLoadFailed(
              title: "The roles didn't load",
              onRetry: () => ref.invalidate(rolePermissionsProvider(_sid)),
            )
          else
            const Center(child: HollowSpinner.medium(delayed: true)),
        ],
      );
    }

    return SettingsPage(
      title: 'Roles',
      intro: intro,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Permission',
                      style: HollowTypography.label
                          .copyWith(color: hollow.textSecondary)),
                ),
                header('Admin'),
                header(touch ? 'Mod' : 'Moderator'),
                header('Member'),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            const HollowDivider(),
            for (final row in _kPermissionRows)
              SettingsRow(
                title: row.title,
                subtitle: row.subtitle,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final role in _kRoles)
                      SizedBox(
                        width: column,
                        child: Center(
                          child: HollowToggle(
                            value: perms(role) & row.bit != 0,
                            semanticLabel: '${row.title} for ${roleDisplayName(role)}',
                            onChanged: canEdit(role)
                                ? (on) {
                                    final before = perms(role);
                                    _write(
                                        role,
                                        on
                                            ? before | row.bit
                                            : before & ~row.bit,
                                        before);
                                  }
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: HollowSpacing.md),
            Row(
              children: [
                Expanded(
                  child: SettingsNote(atDefaults
                      ? 'These are the defaults. Changes apply at once.'
                      : 'Changed from the defaults. Changes apply at once.'),
                ),
                if (editable.isNotEmpty)
                  HollowButton.ghost(
                    compact: true,
                    onPressed: atDefaults
                        ? null
                        : () {
                            for (final r in editable) {
                              final d = data[r]!.defaults;
                              if (perms(r) != d) _write(r, d, perms(r));
                            }
                          },
                    child: const Text('Reset to defaults'),
                  ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

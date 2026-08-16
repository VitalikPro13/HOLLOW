import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart'
    show kGrantDurationOptions;
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Member management from the profile card (issue #48): role change, label
/// assignment, and temporary channel access for ONE member, permission-gated
/// per section. The inverse of the channel-centric grants dialog — same FFI,
/// same LWW grant model, member-first flow.
///
/// [peerId] must be the MASTER identity (roles, labels, and grants are all
/// master-keyed CRDT state).
Future<void> showManageMemberDialog(
  BuildContext context, {
  required String serverId,
  required String peerId,
}) {
  return showHollowDialog(
    context: context,
    builder: (_) => _ManageMemberDialog(serverId: serverId, peerId: peerId),
  );
}

enum _View { overview, pickDuration }

class _ManageMemberDialog extends ConsumerStatefulWidget {
  final String serverId;
  final String peerId;

  const _ManageMemberDialog({required this.serverId, required this.peerId});

  @override
  ConsumerState<_ManageMemberDialog> createState() =>
      _ManageMemberDialogState();
}

class _ManageMemberDialogState extends ConsumerState<_ManageMemberDialog> {
  _View _view = _View.overview;
  ChannelInfo? _pendingChannel;
  bool _busy = false;

  /// Optimistic label selection, seeded ONCE from the member row. A refetch
  /// right after a queued CrdtStore write returns the previous value, so the
  /// chips must never re-seed from the provider (labels-tab `_seeded` rule).
  Set<String>? _labelIds;

  String _memberName(crdt_api.MemberFfi? member) {
    final profiles = ref.read(profileProvider);
    return serverDisplayNameFor(profiles, widget.peerId,
        nickname: member?.nickname ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final member = membersAsync.valueOrNull
        ?.where((m) => m.peerId == widget.peerId)
        .firstOrNull;
    if (member != null) {
      _labelIds ??= member.labels.map((l) => l.labelId).toSet();
    }
    final name = _memberName(member);

    return HollowDialog(
      title: 'Manage $name',
      content: switch (_view) {
        _View.overview => _buildOverview(context, member, name),
        _View.pickDuration => _buildDurationPicker(context, name),
      },
      actions: [
        if (_view == _View.overview)
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          )
        else
          HollowButton.ghost(
            onPressed:
                _busy ? null : () => setState(() => _view = _View.overview),
            child: const Text('Back'),
          ),
      ],
    );
  }

  Widget _buildOverview(
      BuildContext context, crdt_api.MemberFfi? member, String name) {
    final hollow = HollowTheme.of(context);
    if (member == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
        child: Center(
          child: Text(
            'This person is no longer a member of the server.',
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          ),
        ),
      );
    }

    final myRole =
        ref.watch(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';
    final perms =
        ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? 0;
    final myPeerId = ref.watch(identityProvider).peerId;
    final isMe = widget.peerId == myPeerId;

    final canRole = !isMe &&
        canManageRole(myRole, member.role) &&
        assignableRoles(myRole).isNotEmpty;
    final canLabels = (perms & Permission.manageRoles) != 0;
    final canGrants = (perms & Permission.manageChannels) != 0;

    final sections = <Widget>[
      if (canRole) _buildRoleSection(hollow, member, name, myRole),
      if (canLabels) _buildLabelsSection(hollow),
      if (canGrants) _buildGrantsSection(hollow),
    ];
    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
        child: Center(
          child: Text(
            "You don't have permission to manage this member.",
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, section) in sections.indexed) ...[
          if (i > 0) const SizedBox(height: HollowSpacing.md),
          section,
        ],
      ],
    );
  }

  // ── Role ────────────────────────────────────────────────────────────────

  Widget _buildRoleSection(HollowTheme hollow, crdt_api.MemberFfi member,
      String name, String myRole) {
    // Current role first so the selected chip is always present, then the
    // assignable ones in rank order.
    final roles = <String>[
      member.role,
      ...assignableRoles(myRole).where((r) => r != member.role),
    ];
    return SettingsCard(
      title: 'Role',
      children: [
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            for (final role in roles)
              LabelTypeChip(
                icon: _roleIcon(role),
                text: role[0].toUpperCase() + role.substring(1),
                selected: role == member.role,
                onTap: _busy || role == member.role
                    ? () {}
                    : () => _confirmRoleChange(role, name),
              ),
          ],
        ),
      ],
    );
  }

  IconData _roleIcon(String role) => switch (role) {
        'owner' => LucideIcons.crown,
        'admin' => LucideIcons.shield,
        'moderator' => LucideIcons.shieldCheck,
        _ => LucideIcons.user,
      };

  Future<void> _confirmRoleChange(String newRole, String name) async {
    final roleName = newRole[0].toUpperCase() + newRole.substring(1);
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) {
        final h = HollowTheme.of(ctx);
        return HollowDialog(
          title: 'Change role',
          content: Text(
            "Change $name's role to $roleName?",
            style: HollowTypography.body.copyWith(color: h.textSecondary),
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            HollowButton.filled(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Change'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await crdt_api.changeMemberRole(
        serverId: widget.serverId,
        peerId: widget.peerId,
        newRole: newRole,
      );
      // set_* only queues into the CrdtStore actor — give the write a beat
      // before re-reading (same 150ms convention as the grants dialog).
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverMembersProvider(widget.serverId));
      if (mounted) {
        HollowToast.show(context, '$name is now $roleName',
            type: HollowToastType.success);
      }
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not change role',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Labels ──────────────────────────────────────────────────────────────

  Widget _buildLabelsSection(HollowTheme hollow) {
    final labels =
        ref.watch(serverLabelsProvider(widget.serverId)).valueOrNull ??
            const <crdt_api.LabelFfi>[];
    return SettingsCard(
      title: 'Labels',
      children: [
        if (labels.isEmpty)
          Text(
            'This server has no labels yet.',
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          )
        else
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              for (final label in labels)
                LabelChip(
                  label: label,
                  selected: _labelIds?.contains(label.labelId) ?? false,
                  onTap: _busy ? null : () => _toggleLabel(label),
                ),
            ],
          ),
      ],
    );
  }

  Future<void> _toggleLabel(crdt_api.LabelFfi label) async {
    final ids = _labelIds;
    if (ids == null) return;
    final assigned = ids.contains(label.labelId);
    // Optimistic — the chip flips immediately and never re-seeds from a
    // refetch (which could still return the pre-write value).
    setState(() {
      assigned ? ids.remove(label.labelId) : ids.add(label.labelId);
    });
    try {
      if (assigned) {
        await crdt_api.unassignLabel(
          serverId: widget.serverId,
          labelId: label.labelId,
          peerId: widget.peerId,
        );
      } else {
        await crdt_api.assignLabel(
          serverId: widget.serverId,
          labelId: label.labelId,
          peerId: widget.peerId,
        );
      }
      ref.invalidate(serverMembersProvider(widget.serverId));
    } catch (_) {
      if (mounted) {
        setState(() {
          assigned ? ids.add(label.labelId) : ids.remove(label.labelId);
        });
        HollowToast.show(context, 'Could not update label',
            type: HollowToastType.error);
      }
    }
  }

  // ── Temporary channel access ────────────────────────────────────────────

  Widget _buildGrantsSection(HollowTheme hollow) {
    final channels =
        ref.watch(serverChannelsProvider(widget.serverId)).valueOrNull ??
            const <String, ChannelInfo>{};
    // Only label-gated channels can need a grant — everything else already
    // follows the tier ladder. (A redundant grant on a labelled channel the
    // member can see is harmless; computing per-member visibility here would
    // re-implement the Rust predicate.)
    final gated = channels.values
        .where((c) => c.visibilityLabels.isNotEmpty)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return SettingsCard(
      title: 'Temporary channel access',
      children: [
        if (gated.isEmpty)
          Text(
            'No label-gated channels in this server.',
            style:
                HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
          )
        else
          for (final (i, channel) in gated.indexed)
            Padding(
              padding: EdgeInsets.only(
                bottom: i == gated.length - 1 ? 0 : HollowSpacing.sm,
              ),
              child: _grantRow(hollow, channel),
            ),
      ],
    );
  }

  Widget _grantRow(HollowTheme hollow, ChannelInfo channel) {
    final grants = ref
            .watch(channelGrantsProvider(
                (serverId: widget.serverId, channelId: channel.channelId)))
            .valueOrNull ??
        const <crdt_api.ChannelGrantFfi>[];
    final grant =
        grants.where((g) => g.peerId == widget.peerId).firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;

    return Row(
      children: [
        Icon(
          channel.channelType == ChannelType.voice
              ? LucideIcons.volume2
              : LucideIcons.hash,
          size: 14,
          color: hollow.textSecondary,
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    HollowTypography.body.copyWith(color: hollow.textPrimary),
              ),
              if (grant != null)
                Text(
                  grant.permanent
                      ? 'Until revoked'
                      : '${formatMuteRemaining(Duration(milliseconds: (grant.expiresAtMs - now).clamp(0, 1 << 62)))} left',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textTertiary),
                ),
            ],
          ),
        ),
        const SizedBox(width: HollowSpacing.md),
        if (grant != null)
          HollowPressable(
            semanticLabel: 'Revoke access to ${channel.name}',
            onTap: _busy ? null : () => _revoke(channel),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x, size: 14, color: hollow.error),
          )
        else
          HollowButton.outline(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _pendingChannel = channel;
                      _view = _View.pickDuration;
                    }),
            compact: true,
            icon: const Icon(LucideIcons.userPlus),
            child: const Text('Grant'),
          ),
      ],
    );
  }

  Widget _buildDurationPicker(BuildContext context, String name) {
    final hollow = HollowTheme.of(context);
    final channel = _pendingChannel;
    if (channel == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'How long should $name have access to #${channel.name}?',
          style: HollowTypography.body.copyWith(color: hollow.textPrimary),
        ),
        const SizedBox(height: HollowSpacing.md),
        for (final (label, secs) in kGrantDurationOptions)
          Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
            child: HollowButton.outline(
              onPressed: _busy ? null : () => _grant(channel, secs, label),
              expand: true,
              child: Text(label),
            ),
          ),
      ],
    );
  }

  Future<void> _grant(
      ChannelInfo channel, int durationSecs, String label) async {
    setState(() => _busy = true);
    try {
      await crdt_api.grantChannelAccess(
        serverId: widget.serverId,
        channelId: channel.channelId,
        peerId: widget.peerId,
        durationSecs: durationSecs,
      );
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(channelGrantsProvider(
          (serverId: widget.serverId, channelId: channel.channelId)));
      if (mounted) {
        HollowToast.show(context, 'Access granted ($label)',
            type: HollowToastType.success);
        setState(() {
          _busy = false;
          _pendingChannel = null;
          _view = _View.overview;
        });
      }
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not grant access',
            type: HollowToastType.error);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _revoke(ChannelInfo channel) async {
    setState(() => _busy = true);
    try {
      await crdt_api.revokeChannelAccess(
        serverId: widget.serverId,
        channelId: channel.channelId,
        peerId: widget.peerId,
      );
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(channelGrantsProvider(
          (serverId: widget.serverId, channelId: channel.channelId)));
      if (mounted) {
        HollowToast.show(context, 'Access revoked',
            type: HollowToastType.success);
      }
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not revoke access',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

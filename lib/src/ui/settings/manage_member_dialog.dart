import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
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
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_duration_picker.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/settings/moderation_dialogs.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Member management from the profile card (issue #48): role, labels and
/// temporary channel access for ONE member, permission-gated per section. The
/// member-first inverse of the channel-centric grants dialog, on the same FFI.
///
/// [peerId] must be the MASTER identity: roles, labels and grants are all
/// master-keyed CRDT state.
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

/// How a grant's time left reads on a row. One with no end says "someone",
/// since another admin may have given it; the picker's "Until I remove it"
/// is your own choice.
String grantRemainingLabel(crdt_api.ChannelGrantFfi grant) {
  if (grant.permanent) return 'Until someone removes it';
  final left = grant.expiresAtMs - DateTime.now().millisecondsSinceEpoch;
  return '${formatMuteRemaining(Duration(milliseconds: left.clamp(0, 1 << 62)))} '
      'left';
}

/// A grant as it stands right after a write, before the queued write can be
/// read back.
crdt_api.ChannelGrantFfi optimisticGrant(String peerId, Duration? duration) =>
    crdt_api.ChannelGrantFfi(
      peerId: peerId,
      expiresAtMs: duration == null
          ? 0
          : DateTime.now().add(duration).millisecondsSinceEpoch,
      permanent: duration == null,
    );

enum _View { overview, pickDuration }

class _ManageMemberDialog extends ConsumerStatefulWidget {
  final String serverId;
  final String peerId;

  const _ManageMemberDialog({required this.serverId, required this.peerId});

  @override
  ConsumerState<_ManageMemberDialog> createState() =>
      _ManageMemberDialogState();
}

class _ManageMemberDialogState extends ConsumerState<_ManageMemberDialog>
    with HollowDialogAction {
  _View _view = _View.overview;
  ChannelInfo? _pendingChannel;
  Duration? _duration = const Duration(hours: 1);

  /// Optimistic state, seeded ONCE or set by our own writes: a refetch right
  /// after a queued CrdtStore write returns the PREVIOUS value, so what this
  /// dialog wrote wins over the provider until it closes.
  Set<String>? _labelIds;
  String? _role;
  final Map<String, crdt_api.ChannelGrantFfi?> _grants = {};
  final Set<String> _revoking = {};

  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    // By now the writes have landed: other surfaces reread the grants.
    for (final channelId in _grants.keys) {
      _container.invalidate(channelGrantsProvider(
          (serverId: widget.serverId, channelId: channelId)));
    }
    super.dispose();
  }

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

    final Widget overview;
    if (member != null) {
      overview = _buildOverview(context, member, name);
    } else if (membersAsync.isLoading) {
      overview = const Padding(
        padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
        child: Center(child: HollowSpinner.medium()),
      );
    } else if (membersAsync.hasError) {
      overview = const HollowEmptyState(
        dense: true,
        title: "Couldn't load the members of this server",
        description: 'Close this and try again.',
      );
    } else {
      overview = HollowEmptyState(
        dense: true,
        title: "$name isn't a member of this server anymore",
      );
    }

    return HollowDialog(
      title: 'Manage $name',
      width: 480,
      showClose: _view == _View.overview,
      busy: actionRunning,
      error: _view == _View.pickDuration ? actionError : null,
      content: switch (_view) {
        _View.overview => overview,
        _View.pickDuration => _buildDurationPicker(context, name),
      },
      actions: [
        if (_view == _View.pickDuration) ...[
          HollowButton.ghost(
            onPressed: actionRunning
                ? null
                : () => setState(() {
                      _view = _View.overview;
                      actionError = null;
                    }),
            child: const Text('Back'),
          ),
          HollowButton.filled(
            onPressed: _grant,
            loading: actionRunning,
            child: const Text('Give access'),
          ),
        ],
      ],
    );
  }

  Widget _buildOverview(
      BuildContext context, crdt_api.MemberFfi member, String name) {
    final hollow = HollowTheme.of(context);
    final roleAsync = ref.watch(myRoleProvider(widget.serverId));
    final permsAsync = ref.watch(myPermissionsProvider(widget.serverId));
    if (roleAsync.hasError || permsAsync.hasError) {
      return const HollowEmptyState(
        dense: true,
        title: "Couldn't check what you can change here",
        description: 'Close this and try again.',
      );
    }
    // Until both land, "no permission" would be a guess.
    if (!roleAsync.hasValue || !permsAsync.hasValue) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
        child: Center(child: HollowSpinner.medium()),
      );
    }
    final myRole = roleAsync.value!;
    final perms = permsAsync.value!;
    final myPeerId = ref.watch(identityProvider).peerId;
    final isMe = widget.peerId == myPeerId;
    final role = _role ?? member.role;

    final canRole = !isMe &&
        canManageRole(myRole, role) &&
        assignableRoles(myRole).isNotEmpty;
    final canLabels = (perms & Permission.manageRoles) != 0;
    final canGrants = (perms & Permission.manageChannels) != 0;

    final sections = <Widget>[
      if (canRole) _buildRoleSection(role, name, myRole),
      if (canLabels) _buildLabelsSection(),
      if (canGrants) _buildGrantsSection(hollow),
    ];
    if (sections.isEmpty) {
      return const HollowEmptyState(
        dense: true,
        title: "You don't have permission to manage this member",
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, section) in sections.indexed) ...[
          if (i > 0) const SizedBox(height: HollowSpacing.xl),
          section,
        ],
      ],
    );
  }

  Widget _buildRoleSection(String role, String name, String myRole) {
    // Rank order, so the chips never reorder from one member to the next; the
    // current role joins even when it is not one you can assign.
    const rank = ['owner', 'admin', 'moderator', 'member'];
    final roles = {role, ...assignableRoles(myRole)}.toList()
      ..sort((a, b) => rank.indexOf(a).compareTo(rank.indexOf(b)));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HollowSectionHeader('Role', dense: true),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            for (final r in roles)
              Semantics(
                selected: r == role,
                inMutuallyExclusiveGroup: true,
                child: HollowChip(
                  icon: _roleIcon(r),
                  label: roleDisplayName(r),
                  selected: r == role,
                  onTap: r == role ? null : () => _changeRole(role, r, name),
                ),
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

  Future<void> _changeRole(String current, String next, String name) async {
    final changed = await showChangeRoleDialog(
      context,
      ref,
      serverId: widget.serverId,
      peerId: widget.peerId,
      displayName: name,
      newRole: next,
      currentRole: current,
    );
    if (changed && mounted) setState(() => _role = next);
  }

  Widget _buildLabelsSection() {
    final labels =
        ref.watch(serverLabelsProvider(widget.serverId)).valueOrNull ??
            const <crdt_api.LabelFfi>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const HollowSectionHeader('Labels', dense: true),
        if (labels.isEmpty)
          const HollowEmptyState(
              dense: true, title: 'This server has no labels yet')
        else
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              for (final label in labels)
                LabelChip(
                  label: label,
                  selected: _labelIds?.contains(label.labelId) ?? false,
                  onTap: () => _toggleLabel(label),
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
    // The chip flips immediately and never re-seeds from a refetch, which could
    // still return the pre-write value.
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
    } catch (e) {
      if (mounted) {
        setState(() {
          assigned ? ids.add(label.labelId) : ids.remove(label.labelId);
        });
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't change the ${label.name} label. Try "
                    'again.'),
            type: HollowToastType.error);
      }
    }
  }

  Widget _buildGrantsSection(HollowTheme hollow) {
    final channels =
        ref.watch(serverChannelsProvider(widget.serverId)).valueOrNull ??
            const <String, ChannelInfo>{};
    // Only label-gated channels can need a grant; everything else follows the
    // tier ladder. A redundant grant is harmless, and computing per-member
    // visibility here would re-implement the Rust predicate.
    final gated = channels.values
        .where((c) => c.visibilityLabels.isNotEmpty)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HollowSectionHeader('Temporary channel access', dense: true),
        if (gated.isEmpty)
          const HollowEmptyState(
              dense: true, title: 'No channel here needs a label to see it')
        else
          for (final channel in gated) _grantRow(hollow, channel),
      ],
    );
  }

  crdt_api.ChannelGrantFfi? _grantFor(ChannelInfo channel) {
    if (_grants.containsKey(channel.channelId)) {
      return _grants[channel.channelId];
    }
    final grants = ref
            .watch(channelGrantsProvider(
                (serverId: widget.serverId, channelId: channel.channelId)))
            .valueOrNull ??
        const <crdt_api.ChannelGrantFfi>[];
    return grants.where((g) => g.peerId == widget.peerId).firstOrNull;
  }

  Widget _grantRow(HollowTheme hollow, ChannelInfo channel) {
    final grant = _grantFor(channel);
    return HollowListRow(
      leading: Icon(
        channel.channelType == ChannelType.voice
            ? LucideIcons.volume2
            : LucideIcons.hash,
        size: 16,
        color: hollow.textSecondary,
      ),
      title: channel.name,
      subtitle: grant == null ? null : grantRemainingLabel(grant),
      trailing: grant != null
          ? HollowIconButton(
              icon: LucideIcons.x,
              label: 'Remove access to #${channel.name}',
              onPressed: _revoking.contains(channel.channelId)
                  ? null
                  : () => _revoke(channel),
            )
          : HollowButton.outline(
              onPressed: () => setState(() {
                _pendingChannel = channel;
                _view = _View.pickDuration;
              }),
              compact: true,
              semanticLabel: 'Give access to #${channel.name}',
              child: const Text('Give access'),
            ),
    );
  }

  Widget _buildDurationPicker(BuildContext context, String name) {
    final channel = _pendingChannel;
    if (channel == null) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowDialogText(
          'How long should $name have access to #${channel.name}?',
        ),
        const SizedBox(height: HollowSpacing.lg),
        HollowDurationPicker(
          value: _duration,
          onChanged: (d) {
            if (actionRunning) return;
            setState(() {
              _duration = d;
              actionError = null;
            });
          },
        ),
      ],
    );
  }

  Future<void> _grant() async {
    final channel = _pendingChannel;
    if (channel == null) return;
    final duration = _duration;
    final granted = await runDialogAction(() => crdt_api.grantChannelAccess(
          serverId: widget.serverId,
          channelId: channel.channelId,
          peerId: widget.peerId,
          durationSecs: duration?.inSeconds ?? 0,
        ));
    if (!granted || !mounted) return;
    HollowToast.show(
      context,
      duration == null
          ? 'Access given until someone removes it'
          : 'Access given for ${hollowDurationLabel(duration)}',
      type: HollowToastType.success,
    );
    setState(() {
      actionRunning = false;
      _grants[channel.channelId] = optimisticGrant(widget.peerId, duration);
      _pendingChannel = null;
      _view = _View.overview;
    });
  }

  Future<void> _revoke(ChannelInfo channel) async {
    final id = channel.channelId;
    final had = _grants.containsKey(id);
    final before = _grants[id];
    // The row drops the grant now; a failure puts it back.
    setState(() {
      _revoking.add(id);
      _grants[id] = null;
    });
    try {
      await crdt_api.revokeChannelAccess(
        serverId: widget.serverId,
        channelId: id,
        peerId: widget.peerId,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (had) {
          _grants[id] = before;
        } else {
          _grants.remove(id);
        }
      });
      HollowToast.show(
          context,
          friendlyError(e,
              fallback: "Couldn't remove access to #${channel.name}. Try "
                  'again.'),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _revoking.remove(id));
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_duration_picker.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart'
    show grantRemainingLabel, optimisticGrant;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Temporary channel access manager: the active grants and a member picker to
/// add one. A grant removes itself at expiry.
Future<void> showChannelGrantsDialog(
  BuildContext context, {
  required String serverId,
  required String channelId,
  required String channelName,
}) {
  return showHollowDialog(
    context: context,
    builder: (_) => _ChannelGrantsDialog(
      serverId: serverId,
      channelId: channelId,
      channelName: channelName,
    ),
  );
}

enum _View { overview, pickDuration }

class _ChannelGrantsDialog extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  const _ChannelGrantsDialog({
    required this.serverId,
    required this.channelId,
    required this.channelName,
  });

  @override
  ConsumerState<_ChannelGrantsDialog> createState() =>
      _ChannelGrantsDialogState();
}

class _ChannelGrantsDialogState extends ConsumerState<_ChannelGrantsDialog>
    with HollowDialogAction {
  _View _view = _View.overview;
  String? _pendingPeerId;
  String _pendingName = '';
  Duration? _duration = const Duration(hours: 1);

  /// This dialog's own writes by member, null for a removal: a refetch right
  /// after a queued CrdtStore write still returns the previous grants.
  final Map<String, crdt_api.ChannelGrantFfi?> _written = {};
  final Set<String> _revoking = {};
  late final ProviderContainer _container;

  ({String serverId, String channelId}) get _key =>
      (serverId: widget.serverId, channelId: widget.channelId);

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  @override
  void dispose() {
    // By now the writes have landed: other surfaces reread the grants.
    if (_written.isNotEmpty) _container.invalidate(channelGrantsProvider(_key));
    super.dispose();
  }

  List<crdt_api.ChannelGrantFfi> _grants() {
    final stored = ref.watch(channelGrantsProvider(_key)).valueOrNull ??
        const <crdt_api.ChannelGrantFfi>[];
    return [
      for (final g in stored)
        if (!_written.containsKey(g.peerId)) g,
      for (final g in _written.values) ?g,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Temporary access to #${widget.channelName}',
      width: 480,
      showClose: _view == _View.overview,
      busy: actionRunning,
      error: _view == _View.pickDuration ? actionError : null,
      content: switch (_view) {
        _View.overview => _buildOverview(context),
        _View.pickDuration => _buildDurationPicker(context),
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

  Widget _buildOverview(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final grants = _grants();
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final profiles = ref.watch(profileProvider);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';
    final granted = grants.map((g) => g.peerId).toSet();

    String nameFor(String peerId) {
      final member = membersAsync.valueOrNull
          ?.where((m) => m.peerId == peerId)
          .firstOrNull;
      return serverDisplayNameFor(profiles, peerId,
          nickname: member?.nickname ?? '');
    }

    // The id suffix only where it tells two people apart.
    final grantNames = [for (final g in grants) nameFor(g.peerId)];
    String? subtitleFor(int i) {
      final name = grantNames[i];
      final shared = grantNames.where((n) => n == name).length > 1;
      final left = grantRemainingLabel(grants[i]);
      return shared ? '${shortPeerIdSuffix(grants[i].peerId)} · $left' : left;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HollowDialogText(
          'Let one member into this channel for a while. Their access ends '
          'on its own when the time is up.',
        ),
        if (grants.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.xl),
          const HollowSectionHeader('Has access now', dense: true),
          for (final (i, g) in grants.indexed)
            HollowListRow(
              key: ValueKey('grant-${g.peerId}'),
              leading: HollowAvatar(peerId: g.peerId, size: 28),
              title: grantNames[i],
              subtitle: subtitleFor(i),
              trailing: HollowIconButton(
                icon: LucideIcons.x,
                label: 'Remove access for ${grantNames[i]}',
                onPressed:
                    _revoking.contains(g.peerId) ? null : () => _revoke(g),
              ),
            ),
        ],
        const SizedBox(height: HollowSpacing.xl),
        const HollowSectionHeader('Give access', dense: true),
        membersAsync.when(
          data: (members) {
            // Members who can already see via tier or labels are NOT
            // excluded: computing that per-member would re-implement the
            // Rust predicate, and a redundant grant is harmless.
            final candidates = members
                .where((m) =>
                    !granted.contains(m.peerId) && m.peerId != myPeerId)
                .toList();
            if (candidates.isEmpty) {
              return const HollowEmptyState(
                  dense: true, title: 'Everyone else already has access');
            }
            return MemberSearchPicker(
              members: candidates,
              nameOf: (m) => serverDisplayNameFor(profiles, m.peerId,
                  nickname: m.nickname),
              trailingOf: (_) => Icon(LucideIcons.chevronRight,
                  size: 16, color: hollow.textSecondary),
              onTapMember: (m) => setState(() {
                _pendingPeerId = m.peerId;
                _pendingName = serverDisplayNameFor(profiles, m.peerId,
                    nickname: m.nickname);
                _view = _View.pickDuration;
              }),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
            child: Center(child: HollowSpinner.medium()),
          ),
          error: (_, _) => const HollowEmptyState(
            dense: true,
            title: "Couldn't load the members",
            description: 'Close this and try again.',
          ),
        ),
      ],
    );
  }

  Widget _buildDurationPicker(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowDialogText('How long should $_pendingName have access?'),
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
    final peerId = _pendingPeerId;
    if (peerId == null) return;
    final duration = _duration;
    final granted = await runDialogAction(() => crdt_api.grantChannelAccess(
          serverId: widget.serverId,
          channelId: widget.channelId,
          peerId: peerId,
          durationSecs: duration?.inSeconds ?? 0,
        ));
    if (!granted || !mounted) return;
    HollowToast.show(
      context,
      duration == null
          ? '$_pendingName has access until someone removes it'
          : '$_pendingName has access for ${hollowDurationLabel(duration)}',
      type: HollowToastType.success,
    );
    setState(() {
      actionRunning = false;
      _written[peerId] = optimisticGrant(peerId, duration);
      _pendingPeerId = null;
      _view = _View.overview;
    });
  }

  Future<void> _revoke(crdt_api.ChannelGrantFfi grant) async {
    final peerId = grant.peerId;
    final had = _written.containsKey(peerId);
    final before = _written[peerId];
    // The row goes now; a failure brings it back.
    setState(() {
      _revoking.add(peerId);
      _written[peerId] = null;
    });
    try {
      await crdt_api.revokeChannelAccess(
        serverId: widget.serverId,
        channelId: widget.channelId,
        peerId: peerId,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (had) {
          _written[peerId] = before;
        } else {
          _written.remove(peerId);
        }
      });
      HollowToast.show(
          context,
          friendlyError(e,
              fallback: "Couldn't remove their access. Try again."),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _revoking.remove(peerId));
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Grant duration options: (label, seconds); 0 = until revoked. Exported for
/// tests (mirrors kMuteDurationOptions).
const kGrantDurationOptions = <(String, int)>[
  ('15 minutes', 900),
  ('1 hour', 3600),
  ('24 hours', 86400),
  ('Until revoked', 0),
];

/// Temporary channel access manager: active grants (with remaining time +
/// revoke) and a member picker → duration flow to add one. The grant removes
/// itself at expiry — no cleanup clutter.
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

class _ChannelGrantsDialogState extends ConsumerState<_ChannelGrantsDialog> {
  _View _view = _View.overview;
  String? _pendingPeerId;
  String _pendingName = '';
  bool _busy = false;

  ({String serverId, String channelId}) get _key =>
      (serverId: widget.serverId, channelId: widget.channelId);

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Temporary access: #${widget.channelName}',
      content: switch (_view) {
        _View.overview => _buildOverview(context),
        _View.pickDuration => _buildDurationPicker(context),
      },
      actions: [
        if (_view == _View.overview)
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          )
        else
          HollowButton.ghost(
            onPressed: _busy
                ? null
                : () => setState(() => _view = _View.overview),
            child: const Text('Back'),
          ),
      ],
    );
  }

  Widget _buildOverview(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final grants = ref.watch(channelGrantsProvider(_key)).valueOrNull ??
        const <crdt_api.ChannelGrantFfi>[];
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final profiles = ref.watch(profileProvider);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';
    final granted = grants.map((g) => g.peerId).toSet();
    final now = DateTime.now().millisecondsSinceEpoch;

    String nameFor(String peerId) {
      final member = membersAsync.valueOrNull
          ?.where((m) => m.peerId == peerId)
          .firstOrNull;
      return serverDisplayNameFor(profiles, peerId,
          nickname: member?.nickname ?? '');
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Grant a member time-boxed access to this channel. Access is '
          'removed automatically when the timer runs out.',
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textSecondary,
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        if (grants.isNotEmpty) ...[
          SettingsCard(
            title: 'Active Grants',
            children: [
              for (final (i, g) in grants.indexed)
                Padding(
                  padding: EdgeInsets.only(
                    bottom:
                        i == grants.length - 1 ? 0 : HollowSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      HollowAvatar(peerId: g.peerId, size: 28),
                      const SizedBox(width: HollowSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              nameFor(g.peerId),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HollowTypography.body.copyWith(
                                color: hollow.textPrimary,
                              ),
                            ),
                            Text(
                              '${shortPeerIdSuffix(g.peerId)} · '
                              '${g.permanent ? 'Until revoked' : '${formatMuteRemaining(Duration(milliseconds: (g.expiresAtMs - now).clamp(0, 1 << 62)))} left'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.md),
                      HollowPressable(
                        semanticLabel:
                            'Revoke access for ${nameFor(g.peerId)}',
                        onTap: _busy ? null : () => _revoke(g.peerId),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child:
                            Icon(LucideIcons.x, size: 14, color: hollow.error),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
        ],
        SettingsCard(
          title: 'Grant access',
          children: [
            membersAsync.when(
              data: (members) {
                // Exclude members who already hold a grant, and yourself.
                // (Members who can already see via tier/labels are NOT
                // excluded — computing that per-member would re-implement
                // the Rust predicate; a redundant grant is harmless.)
                final candidates = members
                    .where((m) =>
                        !granted.contains(m.peerId) && m.peerId != myPeerId)
                    .toList();
                if (candidates.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: HollowSpacing.lg),
                    child: Center(
                      child: Text(
                        'No members to grant access to',
                        style: HollowTypography.bodySmall.copyWith(
                          color: hollow.textSecondary,
                        ),
                      ),
                    ),
                  );
                }
                return MemberSearchPicker(
                  members: candidates,
                  nameOf: (m) => serverDisplayNameFor(profiles, m.peerId,
                      nickname: m.nickname),
                  trailingOf: (_) => Icon(LucideIcons.chevronRight,
                      size: 16, color: hollow.textSecondary),
                  onTapMember: _busy
                      ? null
                      : (m) => setState(() {
                            _pendingPeerId = m.peerId;
                            _pendingName = serverDisplayNameFor(
                                profiles, m.peerId,
                                nickname: m.nickname);
                            _view = _View.pickDuration;
                          }),
                );
              },
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Error: $e'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDurationPicker(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'How long should $_pendingName have access?',
          style: HollowTypography.body.copyWith(color: hollow.textPrimary),
        ),
        const SizedBox(height: HollowSpacing.md),
        for (final (label, secs) in kGrantDurationOptions)
          Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
            child: HollowButton.outline(
              onPressed: _busy ? null : () => _grant(secs, label),
              expand: true,
              child: Text(label),
            ),
          ),
      ],
    );
  }

  Future<void> _grant(int durationSecs, String label) async {
    final peerId = _pendingPeerId;
    if (peerId == null) return;
    setState(() => _busy = true);
    try {
      await crdt_api.grantChannelAccess(
        serverId: widget.serverId,
        channelId: widget.channelId,
        peerId: peerId,
        durationSecs: durationSecs,
      );
      // set_* only queues into the CrdtStore actor — give the write a beat
      // before re-reading (same 100ms convention as the labels tab).
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(channelGrantsProvider(_key));
      if (mounted) {
        HollowToast.show(
            context, 'Access granted ($label)', type: HollowToastType.success);
        setState(() {
          _busy = false;
          _pendingPeerId = null;
          _view = _View.overview;
        });
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Could not grant access',
            type: HollowToastType.error);
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _revoke(String peerId) async {
    setState(() => _busy = true);
    try {
      await crdt_api.revokeChannelAccess(
        serverId: widget.serverId,
        channelId: widget.channelId,
        peerId: peerId,
      );
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(channelGrantsProvider(_key));
      if (mounted) {
        HollowToast.show(context, 'Access revoked',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Could not revoke access',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

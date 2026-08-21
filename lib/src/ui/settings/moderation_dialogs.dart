/// The four member-moderation confirms — change role, kick, mute, ban — in ONE
/// place (issue #61, phase 3).
///
/// Before this they existed twice: private widgets in
/// `settings/members_tab.dart` and a second copy in
/// `mobile/mobile_members_route.dart`. The desktop user context menu would
/// have made a third. Three copies of a destructive confirm is three chances
/// for one of them to skip a check, word the warning differently, or forget to
/// invalidate the member list afterwards.
///
/// Every function here does the whole job: confirm, call the FFI, invalidate
/// the providers the result changes, and report the outcome. Call sites await
/// nothing and handle nothing. Rust re-checks `op_allowed` on every one of
/// these ops regardless of what the UI allowed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart'
    show mutedMembersProvider;
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
/// Mute durations offered by [showMuteMemberDialog]; 0 means permanent.
const kMuteDurationOptions = <(String, int)>[
  ('10 minutes', 600),
  ('1 hour', 3600),
  ('24 hours', 86400),
  ('7 days', 604800),
  ('Permanent', 0),
];

/// Refreshes everything a moderation op can change.
///
/// The member list carries role AND mute state, and the muted-members section
/// reads its own provider, so both have to go or a settings tab that is
/// already open keeps showing the pre-op state.
void _refresh(WidgetRef ref, String serverId) {
  ref.invalidate(serverMembersProvider(serverId));
  ref.invalidate(mutedMembersProvider(serverId));
}

/// Runs [op] and reports the outcome, so no call site has to.
Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  String serverId, {
  required Future<void> Function() op,
  required String success,
  required String failure,
}) async {
  try {
    await op();
    _refresh(ref, serverId);
    if (context.mounted) {
      HollowToast.show(context, success, type: HollowToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, '$failure: $e', type: HollowToastType.error);
    }
  }
}

/// A confirm with a ghost Cancel and one accented (or destructive) action.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool isDanger = false,
}) async {
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: title,
      content: Text(
        message,
        style: HollowTypography.body
            .copyWith(color: HollowTheme.of(ctx).textSecondary),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        if (isDanger)
          HollowButton.danger(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          )
        else
          HollowButton.filled(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel),
          ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Change [peerId]'s role to [newRole] after a confirm.
Future<void> showChangeRoleDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
  required String newRole,
}) async {
  final roleName = newRole[0].toUpperCase() + newRole.substring(1);
  final ok = await _confirm(
    context,
    title: 'Change role',
    message: 'Change $displayName\'s role to $roleName?',
    confirmLabel: 'Change',
  );
  if (!ok || !context.mounted) return;
  await _run(
    context,
    ref,
    serverId,
    op: () => crdt_api.changeMemberRole(
      serverId: serverId,
      peerId: peerId,
      newRole: newRole,
    ),
    success: '$displayName is now $roleName',
    failure: 'Failed to change role',
  );
}

/// Kick [peerId] from [serverId] after a confirm.
Future<void> showKickMemberDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
}) async {
  final ok = await _confirm(
    context,
    title: 'Kick member',
    message: 'Are you sure you want to kick $displayName from the server? '
        'They can rejoin with an invite.',
    confirmLabel: 'Kick',
    isDanger: true,
  );
  if (!ok || !context.mounted) return;
  await _run(
    context,
    ref,
    serverId,
    op: () => crdt_api.kickMember(serverId: serverId, peerId: peerId),
    success: '$displayName has been kicked',
    failure: 'Failed to kick member',
  );
}

/// Ban [peerId] from [serverId] after a confirm.
Future<void> showBanMemberDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
}) async {
  final ok = await _confirm(
    context,
    title: 'Ban member',
    message: 'Are you sure you want to ban $displayName? They will be removed '
        'and unable to rejoin.',
    confirmLabel: 'Ban',
    isDanger: true,
  );
  if (!ok || !context.mounted) return;
  await _run(
    context,
    ref,
    serverId,
    op: () => crdt_api.banMember(serverId: serverId, peerId: peerId),
    success: '$displayName has been banned',
    failure: 'Failed to ban member',
  );
}

/// Pick a duration, then mute [peerId] for it.
///
/// The duration IS the confirmation — no second "are you sure", the same as
/// the mobile sheet: picking a length is already a deliberate act and a mute
/// is reversible from the Members tab.
Future<void> showMuteMemberDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
}) async {
  final picked = await showHollowDialog<(String, int)>(
    context: context,
    builder: (ctx) {
      final hollow = HollowTheme.of(ctx);
      return HollowDialog(
        title: 'Mute member',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$displayName will not be able to send messages in any channel '
              'of this server. How long?',
              style:
                  HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.md),
            for (final option in kMuteDurationOptions)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                child: HollowButton.ghost(
                  onPressed: () => Navigator.of(ctx).pop(option),
                  expand: true,
                  child: Text(
                    option.$1,
                    style: HollowTypography.body.copyWith(
                      color: option.$2 == 0 ? hollow.error : hollow.textPrimary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
  if (picked == null || !context.mounted) return;

  final (label, durationSecs) = picked;
  await muteMemberFor(
    context,
    ref,
    serverId: serverId,
    peerId: peerId,
    displayName: displayName,
    durationSecs: durationSecs,
    label: label,
  );
}

/// Applies a mute that the caller has already had confirmed.
///
/// Mobile picks the duration in a bottom sheet rather than the dialog above,
/// because a sheet is what every other action list on that platform is. The
/// PICKER differs; the write, the invalidations and the wording must not, so
/// both funnel through here.
Future<void> muteMemberFor(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
  required int durationSecs,
  required String label,
}) {
  return _run(
    context,
    ref,
    serverId,
    op: () => crdt_api.muteMember(
      serverId: serverId,
      peerId: peerId,
      durationSecs: durationSecs,
    ),
    success: durationSecs <= 0
        ? '$displayName is now muted (permanent)'
        : '$displayName is muted for $label',
    failure: 'Failed to mute member',
  );
}

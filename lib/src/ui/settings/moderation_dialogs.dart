/// The member-moderation confirms (change role, kick, mute, ban) in ONE
/// place (issue #61, phase 3): three copies of a destructive confirm is three
/// chances to skip a check or word a warning differently.
///
/// Every function here does the whole job: confirm, call the FFI, invalidate
/// the providers the result changes, and report the outcome. Rust re-checks
/// `op_allowed` on every one of these ops regardless of what the UI allowed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/core/providers/channel_provider.dart'
    show mutedMembersProvider;
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_duration_picker.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Refreshes everything a moderation op can change: the member list carries
/// role AND mute state and the muted-members section reads its own provider, so
/// an open settings tab keeps showing the pre-op state unless both go.
void _refresh(WidgetRef ref, String serverId) {
  ref.invalidate(serverMembersProvider(serverId));
  ref.invalidate(mutedMembersProvider(serverId));
}

/// Asks, runs [op] inside the confirm (a failure shows there, with a retry),
/// then refreshes and reports the success, so no call site has to. True once
/// the op is done.
Future<bool> _confirmAndRun(
  BuildContext context,
  WidgetRef ref,
  String serverId, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  required Future<void> Function() op,
  required String success,
}) async {
  final done = await showHollowConfirm(
    context: context,
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    destructive: destructive,
    onConfirm: op,
  );
  // A ref from a widget that has gone throws, so the context gates both.
  if (!done || !context.mounted) return done;
  _refresh(ref, serverId);
  HollowToast.show(context, success, type: HollowToastType.success);
  return true;
}

/// Change [peerId]'s role to [newRole] after a confirm. THE role confirm:
/// the Members page, the member menu and Manage member all call it.
/// [currentRole], when known, lets the message say what changes.
Future<bool> showChangeRoleDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
  required String newRole,
  String? currentRole,
}) {
  final roleName = roleDisplayName(newRole);
  return _confirmAndRun(
    context,
    ref,
    serverId,
    title: 'Make $displayName ${_withArticle(newRole)}?',
    message: currentRole == null
        ? 'What they can do in this server changes with their role.'
        : 'They go from ${roleDisplayName(currentRole)} to $roleName, which '
            'changes what they can do here.',
    confirmLabel: 'Make ${roleName.toLowerCase()}',
    op: () => crdt_api.changeMemberRole(
      serverId: serverId,
      peerId: peerId,
      newRole: newRole,
    ),
    success: '$displayName is now $roleName',
  );
}

String _withArticle(String role) => switch (role) {
      'owner' => 'the owner',
      'admin' => 'an admin',
      _ => 'a $role',
    };

/// Kick [peerId] from [serverId] after a confirm.
Future<bool> showKickMemberDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
}) {
  return _confirmAndRun(
    context,
    ref,
    serverId,
    title: 'Kick $displayName?',
    message: "They're removed from the server and can rejoin with an invite.",
    confirmLabel: 'Kick',
    destructive: true,
    op: () => crdt_api.kickMember(serverId: serverId, peerId: peerId),
    success: '$displayName was kicked',
  );
}

/// Ban [peerId] from [serverId] after a confirm.
Future<bool> showBanMemberDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
}) {
  return _confirmAndRun(
    context,
    ref,
    serverId,
    title: 'Ban $displayName?',
    message: "They're removed from the server and can't rejoin, even with an "
        'invite.',
    confirmLabel: 'Ban',
    destructive: true,
    op: () => crdt_api.banMember(serverId: serverId, peerId: peerId),
    success: '$displayName was banned',
  );
}

/// Pick a duration, then mute [peerId] for it.
///
/// The duration IS the confirmation: picking a length is already deliberate and
/// a mute is reversible from the Members page. The write runs inside the
/// dialog, so a failure shows there and the moderator can retry.
Future<bool> showMuteMemberDialog(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
}) async {
  Duration? chosen;
  final muted = await showHollowDurationDialog(
    context: context,
    title: 'Mute $displayName',
    message: "They won't be able to post, edit or react anywhere in this "
        'server. For how long?',
    confirmLabel: 'Mute',
    onConfirm: (duration) async {
      chosen = duration;
      await crdt_api.muteMember(
        serverId: serverId,
        peerId: peerId,
        durationSecs: duration?.inSeconds ?? 0,
      );
    },
  );
  if (!muted || !context.mounted) return muted;
  _refresh(ref, serverId);
  HollowToast.show(
    context,
    chosen == null
        ? '$displayName is muted until someone unmutes them'
        : '$displayName is muted for ${hollowDurationLabel(chosen)}',
    type: HollowToastType.success,
  );
  return true;
}

/// Lifts [peerId]'s mute at once: undoing a mute needs no confirm.
Future<void> unmuteMember(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String peerId,
  required String displayName,
}) async {
  try {
    await crdt_api.unmuteMember(serverId: serverId, peerId: peerId);
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(
          context,
          friendlyError(e,
              fallback: "Couldn't unmute $displayName. Try again."),
          type: HollowToastType.error);
    }
    return;
  }
  if (!context.mounted) return;
  _refresh(ref, serverId);
  HollowToast.show(context, '$displayName can post again',
      type: HollowToastType.success);
}

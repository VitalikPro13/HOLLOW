import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What a room asks of a joiner, in words, for the room list's second line.
String conferenceRoomFacts(ConferenceRoom room) {
  final facts = [
    if (room.waitingRoom) 'Waiting room',
    if (room.hasAccessCode) 'Access code',
  ];
  return facts.isEmpty ? 'Anyone with the link can join' : facts.join(' · ');
}

/// Whether the voice room we sit in is the active conference, whose leave has
/// to go through the meeting: a bare voice leave strands the meeting state.
bool inActiveConferenceCall(WidgetRef ref) {
  final conf = ref.read(conferenceProvider);
  if (!conf.meetingActive || conf.activeConfId == null) return false;
  return ref.read(voiceChannelProvider).currentServerId == conf.activeServerId;
}

/// Asks first, then ends the meeting for everyone. The room and its link stay.
Future<void> endConferenceMeeting(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(conferenceProvider.notifier);
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'End the meeting?',
    message: 'Everyone in it is disconnected. The room and its link stay, '
        'so you can start it again.',
    confirmLabel: 'End meeting',
    destructive: true,
  );
  if (!confirmed) return;
  try {
    await notifier.endMeeting();
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't end the meeting",
          type: HollowToastType.error);
    }
  }
}

/// Leaves someone else's meeting, toasting when the leave fails.
Future<void> leaveConferenceMeeting(BuildContext context, WidgetRef ref) async {
  final notifier = ref.read(conferenceProvider.notifier);
  try {
    await notifier.leaveMeeting();
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't leave the meeting",
          type: HollowToastType.error);
    }
  }
}

/// A host ends the meeting, a joiner leaves it.
Future<void> endOrLeaveConferenceMeeting(
    BuildContext context, WidgetRef ref) {
  return ref.read(conferenceProvider).isHost
      ? endConferenceMeeting(context, ref)
      : leaveConferenceMeeting(context, ref);
}

void copyConferenceInviteLink(
    BuildContext context, WidgetRef ref, ConferenceRoom room) {
  Clipboard.setData(
      ClipboardData(text: room.inviteLink(ref.read(relayDomainProvider))));
  HollowToast.show(context, 'Invite link copied',
      type: HollowToastType.success);
}

Future<void> confirmDeleteConferenceRoom(
    BuildContext context, WidgetRef ref, ConferenceRoom room) async {
  final notifier = ref.read(conferenceProvider.notifier);
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Delete room?',
    message: 'Delete "${room.name}"? Its invite link stops working forever.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!confirmed) return;
  try {
    await notifier.deleteRoom(room.confId);
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't delete the room",
          type: HollowToastType.error);
    }
  }
}

/// The room's More menu, from its button, a right click or a long press.
/// [withCopyLink] adds the copy action a phone row has no button for.
void showConferenceRoomMenu(
  BuildContext context,
  WidgetRef ref,
  ConferenceRoom room, {
  required Offset anchor,
  required void Function() onEdit,
  bool alignEnd = false,
  bool withCopyLink = false,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    alignEnd: alignEnd,
    builder: (_, _) => [
      if (withCopyLink)
        HollowMenuItem(
          icon: LucideIcons.link,
          label: 'Copy invite link',
          onTap: () => copyConferenceInviteLink(context, ref, room),
        ),
      HollowMenuItem(
        icon: LucideIcons.pencil,
        label: 'Edit room',
        onTap: onEdit,
      ),
      const HollowMenuDivider(),
      HollowMenuItem(
        icon: LucideIcons.trash2,
        label: 'Delete room',
        isDanger: true,
        onTap: () => confirmDeleteConferenceRoom(context, ref, room),
      ),
    ],
  );
}

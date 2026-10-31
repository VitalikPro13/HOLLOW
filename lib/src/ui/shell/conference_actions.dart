import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart'
    show CallStatus, HostMeetingChoice, callProvider, hostsActiveMeeting;
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart' show ProviderRead;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_button.dart';
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
bool inActiveConferenceCall(WidgetRef ref) => inActiveConferenceCallOf(ref.read);

/// Asks first, then ends the meeting for everyone. The room and its link stay.
Future<void> endConferenceMeeting(BuildContext context, WidgetRef ref) =>
    _askThenEndMeeting(context, ref.read(conferenceProvider.notifier));

Future<void> _askThenEndMeeting(
    BuildContext context, ConferenceNotifier notifier) async {
  await showHollowConfirm(
    context: context,
    title: 'End the meeting?',
    message: 'Everyone in it is disconnected. The room and its link stay, '
        'so you can start it again.',
    confirmLabel: 'End meeting',
    destructive: true,
    onConfirm: notifier.endMeeting,
  );
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

/// [endOrLeaveConferenceMeeting] for code that holds no widget (the tray). The
/// host is still asked first, so [showWindow] brings the question into view;
/// while App Lock covers the window nothing is asked and nothing ends.
Future<void> endOrLeaveConferenceMeetingOf(
  ProviderRead read, {
  required Future<void> Function() showWindow,
}) async {
  final notifier = read(conferenceProvider.notifier);
  if (!read(conferenceProvider).isHost) return notifier.leaveMeeting();
  await showWindow();
  final context = hollowNavigatorKey.currentContext;
  if (context == null || !context.mounted || read(appLockedProvider)) return;
  await _askThenEndMeeting(context, notifier);
}

/// Asks the meeting's host what a DM call does to it; null when they cancel.
/// Anyone else goes on unasked, and so does a host under App Lock, since
/// nothing routes above the cover and the meeting then runs on as before.
Future<HostMeetingChoice?> askMeetingHostBeforeDmCall(
  BuildContext context,
  ProviderRead read, {
  required bool answering,
}) async {
  if (!hostsActiveMeeting(read) || read(appLockedProvider)) {
    return HostMeetingChoice.stepOut;
  }
  return showHollowDialog<HostMeetingChoice>(
    context: context,
    builder: (_) => HostMeetingDialog(answering: answering),
  );
}

/// The host's choice before a DM call: end the meeting or keep it running.
/// Answering, it leaves by itself once the call stops ringing.
class HostMeetingDialog extends ConsumerWidget {
  final bool answering;

  const HostMeetingDialog({super.key, required this.answering});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void choose(HostMeetingChoice? choice) => Navigator.of(context).pop(choice);
    if (answering) {
      ref.listen<CallStatus>(callProvider.select((c) => c.status), (_, status) {
        if (status == CallStatus.ringing) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final route = context.mounted ? ModalRoute.of(context) : null;
          if (route != null && route.isActive) {
            Navigator.of(context).removeRoute(route);
          }
        });
      });
    }
    return HollowDialog(
      title: 'End the meeting too?',
      content: HollowDialogText(answering
          ? "Answering takes you out of the meeting you're hosting. End it for everyone, or keep it running without you."
          : "Calling takes you out of the meeting you're hosting. End it for everyone, or keep it running without you."),
      actions: [
        HollowButton.ghost(
          onPressed: () => choose(null),
          child: const Text('Cancel'),
        ),
        HollowButton.outline(
          danger: true,
          onPressed: () => choose(HostMeetingChoice.endForEveryone),
          child: const Text('End for everyone'),
        ),
        HollowButton.filled(
          onPressed: () => choose(HostMeetingChoice.stepOut),
          child: const Text('Keep it running'),
        ),
      ],
    );
  }
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
  await showHollowConfirm(
    context: context,
    title: 'Delete ${room.name}?',
    message: 'Its invite link stops working for good.',
    confirmLabel: 'Delete room',
    destructive: true,
    onConfirm: () => notifier.deleteRoom(room.confId),
  );
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

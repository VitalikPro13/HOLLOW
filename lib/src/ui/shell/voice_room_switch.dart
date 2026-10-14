import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// Whether joining [serverId]/[channelId] would pull us out of a voice room
/// where someone else is talking with us. Moving from an empty room, or into
/// the room we are already in, leaves nobody behind.
///
/// The participant sets are DEVICE-keyed and hold us too, so both our id
/// forms ([master], [device]) are left out of the count.
bool voiceSwitchLeavesPeople(
  VoiceChannelState vc, {
  required String serverId,
  required String channelId,
  required String master,
  String? device,
}) {
  final fromServer = vc.currentServerId;
  final fromChannel = vc.currentChannelId;
  if (fromServer == null || fromChannel == null) return false;
  if (fromServer == serverId && fromChannel == channelId) return false;
  return vc.getParticipants(fromServer, fromChannel).any((p) =>
      p.isNotEmpty && p != master && (device == null || p != device));
}

/// Asks before a voice-room join that would leave people behind; true when the
/// join should go ahead. Every surface that joins a voice room calls this
/// first, desktop and phone, so switching asks in exactly one situation, and
/// "Don't ask again" (#106) silences it everywhere until Settings turns it on.
Future<bool> confirmVoiceRoomSwitch(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String channelId,
  required String channelName,
}) async {
  final vc = ref.read(voiceChannelProvider);
  final leaves = voiceSwitchLeavesPeople(
    vc,
    serverId: serverId,
    channelId: channelId,
    master: ref.read(identityProvider).peerId ?? '',
    device: ref.read(localDevicePeerIdProvider).valueOrNull,
  );
  if (!leaves) return true;
  final current = vc.currentChannelName;
  // The opt-out saves after the caller may be gone; the container outlives it.
  final container = ProviderScope.containerOf(context, listen: false);
  final ask = await container
      .read(askBeforeVoiceSwitchProvider.future)
      .catchError((_) => kAskBeforeVoiceSwitchDefault);
  if (!ask) return true;
  if (!context.mounted) return false;
  return showHollowConfirm(
    context: context,
    title: 'Switch voice room?',
    message: current == null || current.isEmpty
        ? "You'll leave your current voice room and join #$channelName."
        : "You'll leave #$current and join #$channelName.",
    confirmLabel: 'Switch',
    optOutLabel: "Don't ask again",
    onOptOut: () => container
        .read(askBeforeVoiceSwitchProvider.notifier)
        .setEnabled(false),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/ptt_mic_visual.dart';
import 'package:hollow/src/ui/shell/conference_actions.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Leaves the voice room, toasting when the leave fails. Inside a conference
/// it leaves (or, for the host, ends) the meeting instead.
Future<void> leaveVoiceRoom(BuildContext context, WidgetRef ref) async {
  if (inActiveConferenceCall(ref)) {
    return endOrLeaveConferenceMeeting(context, ref);
  }
  try {
    await ref.read(voiceChannelProvider.notifier).leaveChannel();
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't leave the voice room",
          type: HollowToastType.error);
    }
  }
}

/// Whether the dock carries call controls: a DM call you placed or joined, or
/// a voice room you are in. An incoming ring belongs to its card.
bool watchHasQuickControls(WidgetRef ref) {
  final dm = ref.watch(callProvider.select((c) =>
      c.status != CallStatus.idle &&
      !(c.status == CallStatus.ringing &&
          c.direction == CallDirection.incoming)));
  final inVoice =
      ref.watch(voiceChannelProvider.select((s) => s.isInVoiceChannel));
  return dm || inVoice;
}

/// Mute, deafen and Leave for the call you are in, DM or voice room: the dock
/// is how the call is reached from anywhere, so these stay whatever is on
/// screen. While a DM call rings out, just Cancel.
class VoiceQuickControls extends ConsumerWidget {
  const VoiceQuickControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider.select((c) => (
          status: c.status,
          direction: c.direction,
          muted: c.isMuted,
          deafened: c.isDeafened,
        )));
    if (call.status == CallStatus.ringing &&
        call.direction == CallDirection.incoming) {
      return const SizedBox.shrink();
    }
    if (call.status == CallStatus.ringing) {
      return HollowIconButton(
        icon: LucideIcons.phoneOff,
        label: 'Cancel',
        tooltip: 'Cancel the call',
        color: HollowTheme.of(context).error,
        onPressed: () => leaveDmCall(context, ref),
      );
    }
    if (call.status != CallStatus.idle) {
      final calls = ref.read(callProvider.notifier);
      return _QuickRow(
        muted: call.muted,
        deafened: call.deafened,
        onMute: calls.toggleMute,
        onDeafen: calls.toggleDeafen,
        leaveLabel: 'Leave the call',
        onLeave: () => leaveDmCall(context, ref),
      );
    }

    final (inVoice, muted, deafened) = ref.watch(voiceChannelProvider
        .select((s) => (s.isInVoiceChannel, s.isMuted, s.isDeafened)));
    if (!inVoice) return const SizedBox.shrink();
    final notifier = ref.read(voiceChannelProvider.notifier);
    return _QuickRow(
      muted: muted,
      deafened: deafened,
      onMute: notifier.toggleMute,
      onDeafen: notifier.toggleDeafen,
      leaveLabel: inActiveConferenceCall(ref)
          ? 'Leave the meeting'
          : 'Leave the room',
      onLeave: () => leaveVoiceRoom(context, ref),
    );
  }
}

class _QuickRow extends ConsumerWidget {
  final bool muted;
  final bool deafened;
  final VoidCallback onMute;
  final VoidCallback onDeafen;
  final String leaveLabel;
  final VoidCallback onLeave;

  const _QuickRow({
    required this.muted,
    required this.deafened,
    required this.onMute,
    required this.onDeafen,
    required this.leaveLabel,
    required this.onLeave,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final mic = micButtonVisual(ref,
        isMuted: muted, hollow: hollow, idleColor: hollow.textSecondary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowIconButton(
          icon: mic.icon,
          label: muted ? 'Unmute' : 'Mute',
          tooltip: mic.tooltip,
          color: mic.color,
          selected: muted,
          onPressed: onMute,
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowIconButton(
          icon: deafened ? LucideIcons.headphoneOff : LucideIcons.headphones,
          label: deafened ? 'Undeafen' : 'Deafen',
          color: deafened ? hollow.error : null,
          selected: deafened,
          onPressed: onDeafen,
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowIconButton(
          icon: LucideIcons.phoneOff,
          label: leaveLabel,
          color: hollow.error,
          onPressed: onLeave,
        ),
      ],
    );
  }
}

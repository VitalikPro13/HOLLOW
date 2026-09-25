import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
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

/// Mute, deafen and leave for the voice room you are in, the three controls
/// every screen needs; camera and screen share stay in the room's own pill.
class VoiceQuickControls extends ConsumerWidget {
  const VoiceQuickControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final (muted, deafened) = ref.watch(
        voiceChannelProvider.select((s) => (s.isMuted, s.isDeafened)));
    final mic = micButtonVisual(ref,
        isMuted: muted, hollow: hollow, idleColor: hollow.textSecondary);
    final notifier = ref.read(voiceChannelProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowIconButton(
          icon: mic.icon,
          label: muted ? 'Unmute' : 'Mute',
          tooltip: mic.tooltip,
          color: mic.color,
          selected: muted,
          onPressed: notifier.toggleMute,
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowIconButton(
          icon: LucideIcons.headphones,
          label: deafened ? 'Undeafen' : 'Deafen',
          color: deafened ? hollow.error : null,
          selected: deafened,
          onPressed: notifier.toggleDeafen,
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowIconButton(
          icon: LucideIcons.phoneOff,
          label: 'Disconnect',
          color: hollow.error,
          onPressed: () => leaveVoiceRoom(context, ref),
        ),
      ],
    );
  }
}

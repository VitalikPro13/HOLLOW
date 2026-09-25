import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/call/speaking_ring.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';
import 'package:hollow/src/ui/shell/conference_actions.dart'
    show inActiveConferenceCall;
import 'package:hollow/src/ui/shell/voice_quick_controls.dart';

/// The mobile nav bar's height plus its top hairline.
const double _kNavBarReserve = MobileCallMetrics.bar + 1;

/// The call you are in, minimised: who it is with, the timer, Mute and a red
/// Leave. Tapping it opens the call. The shell floats it above the nav bar; a
/// chat docks it under its header.
class MobileMinimisedCall extends ConsumerWidget {
  final bool floating;

  const MobileMinimisedCall({super.key, this.floating = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dm = ref.watch(callProvider.select((c) =>
        c.status != CallStatus.idle &&
        !(c.status == CallStatus.ringing &&
            c.direction == CallDirection.incoming)));
    final inRoom =
        ref.watch(voiceChannelProvider.select((s) => s.isInVoiceChannel));
    if (!dm && !inRoom) return const SizedBox.shrink();

    final bar = dm ? const _DmCallBar() : const _RoomCallBar();
    final hollow = HollowTheme.of(context);
    final framed = DecoratedBox(
      decoration: BoxDecoration(
        color: hollow.overlay,
        borderRadius: BorderRadius.circular(hollow.radiusXl),
        border: Border.all(color: hollow.border),
        boxShadow: floating ? HollowShadows.float : null,
      ),
      child: SizedBox(height: MobileCallMetrics.bar, child: bar),
    );
    if (!floating) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            HollowSpacing.md, HollowSpacing.xs, HollowSpacing.md,
            HollowSpacing.xs),
        child: framed,
      );
    }
    return Positioned(
      left: HollowSpacing.md,
      right: HollowSpacing.md,
      bottom: MediaQuery.viewPaddingOf(context).bottom +
          _kNavBarReserve +
          HollowSpacing.md,
      child: framed,
    );
  }
}

/// The shared row: the body that opens the call, then Mute and Leave.
class _CallBarRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final Widget subtitle;
  final String openLabel;
  final VoidCallback onOpen;
  final Widget mute;
  final Widget leave;

  const _CallBarRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.openLabel,
    required this.onOpen,
    required this.mute,
    required this.leave,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: HollowPressable(
            onTap: onOpen,
            semanticLabel: openLabel,
            borderRadius: BorderRadius.circular(hollow.radiusXl),
            padding: const EdgeInsets.only(
                left: HollowSpacing.md, right: HollowSpacing.sm),
            child: SizedBox(
              height: MobileCallMetrics.bar,
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: HollowSpacing.md),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HollowTypography.label
                              .copyWith(color: hollow.textPrimary),
                        ),
                        DefaultTextStyle.merge(
                          style: HollowTypography.monoSmall.copyWith(
                            color: hollow.success,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          maxLines: 1,
                          child: subtitle,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        mute,
        const SizedBox(width: HollowSpacing.xs),
        leave,
        const SizedBox(width: HollowSpacing.sm),
      ],
    );
  }
}

class _DmCallBar extends ConsumerWidget {
  const _DmCallBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final call = ref.watch(callProvider);
    final master = ref.watch(deviceLinkProvider).identityOf(call.peerId ?? '');
    final name = dmCallPeerName(ref, master);
    final ringingOut = call.status == CallStatus.ringing;
    final startedAt = call.startedAt;
    final Widget subtitle = call.status == CallStatus.active && startedAt != null
        ? CallDurationText(startedAt: startedAt)
        : Text(ringingOut ? 'Calling' : 'Connecting',
            style: TextStyle(color: hollow.textTertiary));
    final speaking = ref.watch(callSpeakingProvider.select((s) => s.remote)) &&
        !call.remoteMuted;
    return _CallBarRow(
      leading: SpeakingRing(
        speaking: speaking,
        color: callRingColor(hollow, isSelf: false, master: master),
        radius: hollow.radiusMd,
        child: HollowAvatar(
            peerId: master, size: MobileCallMetrics.barAvatar, frameId: ''),
      ),
      title: name,
      subtitle: subtitle,
      openLabel: 'Open the call with $name',
      onOpen: () =>
          openMobileDmCall(Navigator.of(context, rootNavigator: true), master),
      mute: CallMuteButton(
        muted: call.isMuted,
        size: MobileCallMetrics.touch,
        onPressed: ringingOut
            ? null
            : () => ref.read(callProvider.notifier).toggleMute(),
      ),
      leave: CallLeaveButton(
        label: ringingOut ? 'Cancel' : 'Leave the call',
        width: MobileCallMetrics.touch,
        height: MobileCallMetrics.touch,
        onPressed: () => leaveDmCall(context, ref),
      ),
    );
  }
}

class _RoomCallBar extends ConsumerWidget {
  const _RoomCallBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vc = ref.watch(voiceChannelProvider);
    final serverId = vc.currentServerId ?? '';
    final channelId = vc.currentChannelId ?? '';
    final name = vc.currentChannelName ?? 'Voice';
    final conference = inActiveConferenceCall(ref);
    final server = conference
        ? null
        : ref.watch(serverListProvider.select((s) => s[serverId]));
    final joinedAt = vc.joinedAt;
    return _CallBarRow(
      leading: server == null
          ? const SizedBox.shrink()
          : ServerAvatar(
              serverId: serverId,
              name: server.name,
              size: MobileCallMetrics.barAvatar,
            ),
      title: name,
      subtitle: joinedAt == null
          ? const SizedBox.shrink()
          : CallDurationText(startedAt: joinedAt),
      openLabel: conference ? 'Open the meeting' : 'Open the room $name',
      onOpen: () => openMobileVoiceRoom(
        Navigator.of(context, rootNavigator: true),
        serverId: serverId,
        channelId: channelId,
        channelName: name,
      ),
      mute: CallMuteButton(
        muted: vc.isMuted,
        size: MobileCallMetrics.touch,
        onPressed: () => ref.read(voiceChannelProvider.notifier).toggleMute(),
      ),
      leave: CallLeaveButton(
        label: conference ? 'Leave the meeting' : 'Leave the room',
        width: MobileCallMetrics.touch,
        height: MobileCallMetrics.touch,
        // Through the conference-aware path, never a bare leaveChannel (B6).
        onPressed: () => leaveVoiceRoom(context, ref),
      ),
    );
  }
}

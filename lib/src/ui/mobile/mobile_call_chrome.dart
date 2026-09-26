import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/audio_route_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/audio_route.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/call/share_tile.dart';
import 'package:hollow/src/ui/call/speaking_ring.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/share_volume_control.dart';
import 'package:hollow/src/ui/mobile/mobile_audio_route_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_screen_share_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';


/// Android or iOS: the speaker, the flip and the OS share picker exist there.
/// Read from the target platform, which is the device's own outside tests.
bool get isPhoneCallPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// The phone call surfaces' sizes (design language session 23).
abstract final class MobileCallMetrics {
  static const double touch = 44;
  static const double control = 56;

  /// The control size once a seventh control (flip camera) joins the row.
  static const double controlTight = 48;
  static const double peerAvatar = 132;
  static const double selfAvatar = 56;
  static const double roomAvatar = 56;
  static const double watchAvatar = 52;
  static const double roomTile = 128;
  static const double bar = 56;
  static const double barAvatar = 36;
  static const double incomingAvatar = 128;
  static const double incomingButton = 72;
  static const double pipWidth = 90;
  static const double pipHeight = 120;
}

/// Route names, so the call's surfaces can tell whether they are showing.
const String kMobileCallRouteName = 'call-screen';
const String kMobileVoiceRouteName = 'voice-room';

// --- Getting to a call and back ----------------------------------------------

/// Opens the DM call screen with [master]. Takes a navigator, because the
/// incoming screen that calls it sits above the app's navigator.
Future<void> openMobileDmCall(NavigatorState nav, String master) =>
    nav.push(hollowMobileRoute(
      settings: const RouteSettings(name: kMobileCallRouteName),
      transition: HollowRouteTransition.slideUp,
      builder: (_) => MobileCallScreen(peerId: master),
    ));

/// Opens the voice room (or meeting) you are in.
Future<void> openMobileVoiceRoom(
  NavigatorState nav, {
  required String serverId,
  required String channelId,
  required String channelName,
}) =>
    nav.push(hollowMobileRoute(
      settings: const RouteSettings(name: kMobileVoiceRouteName),
      transition: HollowRouteTransition.slideUp,
      builder: (_) => MobileVoiceChannelRoute(
        serverId: serverId,
        channelId: channelId,
        channelName: channelName,
      ),
    ));

/// "Open the chat": the call steps down and its conversation shows. The chat
/// the call was opened from is already under it; any other one is opened.
void openMobileCallChat(
  BuildContext context, {
  String? peer,
  String? serverId,
  String? channelId,
  String channelName = '',
}) {
  // The call screen is gone by the time the chat pops, so nothing below may
  // lean on its ref.
  final container = ProviderScope.containerOf(context);
  if (container.read(appLockedProvider)) return;
  final nav = Navigator.of(context, rootNavigator: true);
  final showing = peer != null
      ? container.read(selectedPeerProvider) == peer
      : container.read(selectedServerProvider) == serverId &&
          container.read(selectedChannelProvider) == channelId;
  nav.pop();
  if (showing) return;
  if (peer != null) {
    container.read(selectedPeerProvider.notifier).state = peer;
    container.read(selectedServerProvider.notifier).state = null;
  } else {
    container.read(selectedServerProvider.notifier).state = serverId;
    container.read(selectedChannelProvider.notifier).state = channelId;
  }
  nav.popUntil(
      (r) => r.settings.name != MobileChatRoute.routeName || r.isFirst);
  nav
      .push(hollowMobileRoute(
    settings: const RouteSettings(name: MobileChatRoute.routeName),
    builder: (_) => MobileChatRoute(
      peerId: peer,
      serverId: serverId,
      channelId: channelId,
      channelName: channelName,
    ),
  ))
      .then((_) {
    // Guarded: a notification tap may have replaced this chat already.
    if (peer != null) {
      if (container.read(selectedPeerProvider) == peer) {
        container.read(selectedPeerProvider.notifier).state = null;
      }
    } else if (container.read(selectedChannelProvider) == channelId) {
      container.read(selectedServerProvider.notifier).state = null;
      container.read(selectedChannelProvider.notifier).state = null;
    }
  });
}

/// Starts or stops your share. The phone shares its whole screen through the
/// OS picker; a narrow desktop window keeps the desktop picker.
Future<void> toggleMobileShare(BuildContext context, WidgetRef ref,
    {required bool dm}) async {
  if (!isPhoneCallPlatform) {
    return dm
        ? toggleDmScreenShare(context, ref)
        : toggleVcScreenShare(context, ref);
  }
  final sharing = dm
      ? ref.read(callProvider).isScreenSharing
      : ref.read(voiceChannelProvider).isScreenSharing;
  if (sharing) {
    return dm
        ? ref.read(callProvider.notifier).stopScreenShare()
        : ref.read(voiceChannelProvider.notifier).stopScreenShare();
  }
  final choice = await showMobileScreenShareSheet(context);
  if (choice == null || !context.mounted) return;
  // Android ignores these and captures at the display's size; the encoder cap
  // does the real downscaling.
  try {
    if (dm) {
      await ref.read(callProvider.notifier).startScreenShare(
            sourceId: 'screen',
            width: 1080,
            height: 1920,
            fps: 30,
            shareAudio: choice.shareAudio,
          );
    } else {
      await ref.read(voiceChannelProvider.notifier).startScreenShare(
          'screen', 1080, 1920, 30,
          shareAudio: choice.shareAudio);
    }
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't share your screen",
          type: HollowToastType.error);
    }
  }
}

// --- The top bar ---------------------------------------------------------------

/// The call screen's top: Minimise the call, the title over a mono subtitle
/// (the timer, or "Synth Lab · 42:17"), Open the chat.
class MobileCallTopBar extends ConsumerWidget {
  final String title;
  final Widget? subtitle;
  final VoidCallback onMinimise;

  /// Null where the call has no chat to open.
  final VoidCallback? onOpenChat;

  const MobileCallTopBar({
    super.key,
    required this.title,
    required this.onMinimise,
    this.subtitle,
    this.onOpenChat,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // The chat would open ABOVE the lock cover.
    final openChat = ref.watch(appLockedProvider) ? null : onOpenChat;
    return SizedBox(
      height: MobileCallMetrics.bar,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
        child: Row(
          children: [
            HollowIconButton(
              icon: LucideIcons.chevronDown,
              label: 'Minimise the call',
              size: MobileCallMetrics.touch,
              color: hollow.textPrimary,
              onPressed: onMinimise,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.subheading
                        .copyWith(color: hollow.textPrimary),
                  ),
                  if (subtitle != null)
                    DefaultTextStyle.merge(
                      style: HollowTypography.monoSmall.copyWith(
                        color: hollow.textTertiary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child: subtitle!,
                    ),
                ],
              ),
            ),
            if (openChat != null)
              HollowIconButton(
                icon: LucideIcons.messageCircle,
                label: 'Open the chat',
                size: MobileCallMetrics.touch,
                color: hollow.textPrimary,
                onPressed: openChat,
              )
            else
              const SizedBox.square(dimension: MobileCallMetrics.touch),
          ],
        ),
      ),
    );
  }
}

// --- The control row -------------------------------------------------------------

/// How a call control reads: at rest, on (speaker, camera, sharing), in alarm
/// (muted, deafened), or the red End.
enum MobileControlTone { rest, on, alarm, end }

class MobileCallControl {
  final IconData icon;

  /// The word under the button.
  final String label;

  /// What a screen reader says, when the word under it is not the whole
  /// purpose ("Camera" is "Turn on camera").
  final String? semanticLabel;
  final MobileControlTone tone;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const MobileCallControl({
    required this.icon,
    required this.label,
    this.semanticLabel,
    this.tone = MobileControlTone.rest,
    this.onTap,
    this.onLongPress,
  });
}

/// One row of round controls, each with its word under it. Six are 56 across;
/// a seventh shrinks them all to 48, and a narrow phone shrinks them to fit.
class MobileCallControlRow extends StatelessWidget {
  final List<MobileCallControl> controls;

  const MobileCallControlRow({super.key, required this.controls});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.lg,
        HollowSpacing.lg,
        HollowSpacing.lg,
        HollowSpacing.lg,
      ),
      child: LayoutBuilder(builder: (context, box) {
        final n = controls.length;
        final slot = box.maxWidth / math.max(n, 1);
        final preferred = n >= 7
            ? MobileCallMetrics.controlTight
            : MobileCallMetrics.control;
        final size = math.min(preferred, slot - HollowSpacing.xxs);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final c in controls)
              SizedBox(
                width: slot,
                child: _MobileControlButton(control: c, size: size),
              ),
          ],
        );
      }),
    );
  }
}

class _MobileControlButton extends StatelessWidget {
  final MobileCallControl control;
  final double size;

  const _MobileControlButton({required this.control, required this.size});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final (fill, ink) = switch (control.tone) {
      MobileControlTone.rest => (hollow.hover, hollow.textPrimary),
      MobileControlTone.on => (hollow.textPrimary, hollow.background),
      MobileControlTone.alarm => (
          hollow.error.withValues(alpha: 0.18),
          hollow.error
        ),
      MobileControlTone.end => (hollow.errorFill, hollow.textOnError),
    };
    final enabled = control.onTap != null;
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.4,
      duration: HollowDurations.fast,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowPressable(
            onTap: control.onTap,
            onLongPress: control.onLongPress,
            disabled: !enabled,
            semanticLabel: control.semanticLabel ?? control.label,
            borderRadius: BorderRadius.circular(size / 2),
            backgroundColor: fill,
            child: SizedBox.square(
              dimension: size,
              child: Icon(control.icon,
                  size: size >= MobileCallMetrics.control ? 24 : 20,
                  color: ink),
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
          ExcludeSemantics(
            child: Text(
              control.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mute, with push-to-talk left to the desktop bar: a phone has no key to hold.
MobileCallControl muteControl({required bool muted, VoidCallback? onTap}) =>
    MobileCallControl(
      icon: muted ? LucideIcons.micOff : LucideIcons.mic,
      label: muted ? 'Unmute' : 'Mute',
      tone: muted ? MobileControlTone.alarm : MobileControlTone.rest,
      onTap: onTap,
    );

MobileCallControl deafenControl({required bool deafened, VoidCallback? onTap}) =>
    MobileCallControl(
      icon: deafened ? LucideIcons.headphoneOff : LucideIcons.headphones,
      label: deafened ? 'Undeafen' : 'Deafen',
      tone: deafened ? MobileControlTone.alarm : MobileControlTone.rest,
      onTap: onTap,
    );

MobileCallControl cameraControl({required bool on, VoidCallback? onTap}) =>
    MobileCallControl(
      icon: on ? LucideIcons.video : LucideIcons.videoOff,
      label: 'Camera',
      semanticLabel: on ? 'Turn off camera' : 'Turn on camera',
      tone: on ? MobileControlTone.on : MobileControlTone.rest,
      onTap: onTap,
    );

MobileCallControl shareControl({required bool sharing, VoidCallback? onTap}) =>
    MobileCallControl(
      icon: sharing ? LucideIcons.monitorOff : LucideIcons.monitorUp,
      label: 'Share',
      semanticLabel: sharing ? 'Stop sharing' : 'Share your screen',
      tone: sharing ? MobileControlTone.on : MobileControlTone.rest,
      onTap: onTap,
    );

MobileCallControl flipControl({VoidCallback? onTap}) => MobileCallControl(
      icon: LucideIcons.switchCamera,
      label: 'Flip',
      semanticLabel: 'Flip camera',
      onTap: onTap,
    );

MobileCallControl leaveControl(
        {required String word, required String purpose, VoidCallback? onTap}) =>
    MobileCallControl(
      icon: LucideIcons.phoneOff,
      label: word,
      semanticLabel: purpose,
      tone: MobileControlTone.end,
      onTap: onTap,
    );

/// Speaker: tap for loud and back, long press for the route sheet (a tap too
/// once a headset or car is there). The toggle goes through the provider's
/// `preferLoudRoute`, so a connected headset always keeps the audio.
MobileCallControl speakerControl(
  BuildContext context,
  WidgetRef ref, {
  required bool on,
  required VoidCallback toggle,
  required Future<void> Function(AudioRoute route) select,
  bool enabled = true,
}) {
  final routes = ref.watch(audioRouteProvider);
  final active = routes.activeRoute;
  Future<void> sheet() => showMobileAudioRouteSheet(context, onSelect: select);
  return MobileCallControl(
    icon: audioRouteIcon(routes.activeKind),
    label: 'Speaker',
    semanticLabel: active == null ? 'Speaker' : 'Audio device, ${active.label}',
    tone: on ? MobileControlTone.on : MobileControlTone.rest,
    onTap: !enabled ? null : (routes.hasExternalRoute ? sheet : toggle),
    onLongPress: enabled ? sheet : null,
  );
}

// --- People ---------------------------------------------------------------------

/// A person on a phone call screen: their avatar with the speaking ring in
/// their colour (yours the accent), the name in that colour under it, and the
/// mute mark beside the name.
class MobileCallFace extends ConsumerWidget {
  final CallPerson person;
  final double size;
  final bool largeRing;
  final TextStyle? nameStyle;
  final bool showName;

  const MobileCallFace({
    super.key,
    required this.person,
    required this.size,
    this.largeRing = false,
    this.nameStyle,
    this.showName = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final speaking = ref.watch(person.speaking) && !person.muted;
    final ringColor =
        callRingColor(hollow, isSelf: person.isSelf, master: person.master);
    final avatar = HollowAvatar(peerId: person.master, size: size, frameId: '');
    final ring = largeRing
        ? SpeakingRing.large(
            speaking: speaking,
            color: ringColor,
            radius: hollow.radiusMd,
            child: avatar)
        : SpeakingRing(
            speaking: speaking,
            color: ringColor,
            radius: hollow.radiusMd,
            child: avatar);
    final marks = [
      if (person.muted) 'muted',
      if (person.deafened) 'deafened',
    ];
    return Semantics(
      container: true,
      label: [person.name, ...marks].join(', '),
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ring,
            if (showName) ...[
              const SizedBox(height: HollowSpacing.sm),
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxWidth: math.max(size + HollowSpacing.lg, 72)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (person.muted) ...[
                      Icon(LucideIcons.micOff, size: 14, color: hollow.error),
                      const SizedBox(width: HollowSpacing.xs),
                    ],
                    Flexible(
                      child: Text(
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (nameStyle ?? HollowTypography.bodySmall)
                            .copyWith(
                          color: callNameColor(hollow,
                              isSelf: person.isSelf, master: person.master),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Everyone in the room as a two-column grid of 128 tall tiles: the camera
/// fills a tile while it is on, so nobody drops out of sight.
class MobileRoomGrid extends StatelessWidget {
  final List<CallPerson> people;

  /// A long press on a tile: the person's menu (volume), where they have one.
  final void Function(CallPerson person, Offset globalPosition)? onLongPress;

  const MobileRoomGrid({super.key, required this.people, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = (box.maxWidth - HollowSpacing.md) / 2;
      final press = onLongPress;
      return Wrap(
        spacing: HollowSpacing.md,
        runSpacing: HollowSpacing.md,
        children: [
          for (final p in people)
            SizedBox(
              key: ValueKey('room-tile-${p.id}'),
              width: width,
              height: MobileCallMetrics.roomTile,
              child: GestureDetector(
                onLongPressStart: press == null || p.onMenu == null
                    ? null
                    : (d) => press(p, d.globalPosition),
                child: CallPersonTile(
                  person: p,
                  size: CallTileSize.large,
                  avatarSize: MobileCallMetrics.roomAvatar,
                ),
              ),
            ),
        ],
      );
    });
  }
}

// --- Shares ----------------------------------------------------------------------

/// Someone's share nothing streams from until Watch (issue #38): a full-width
/// card in a room, a one-line strip under the name in a DM.
class MobileShareOffer extends StatelessWidget {
  final CallShare share;
  final VoidCallback? onWatch;

  /// The DM's form: "Sharing their screen", the name already on screen.
  final bool compact;

  const MobileShareOffer({
    super.key,
    required this.share,
    required this.onWatch,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final watch = HollowButton.outline(
      compact: true,
      semanticLabel: "Watch ${share.name}'s screen",
      onPressed: onWatch,
      child: const Text('Watch'),
    );
    if (compact) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusLg),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.md,
            HollowSpacing.xs,
            HollowSpacing.xs,
            HollowSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sharing their screen',
                  style: HollowTypography.label
                      .copyWith(color: hollow.textSecondary)),
              const SizedBox(width: HollowSpacing.sm),
              watch,
            ],
          ),
        ),
      );
    }
    final quality = share.quality;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusLg),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.md,
        ),
        child: Row(
          children: [
            Icon(LucideIcons.monitor, size: 20, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: share.name,
                        style: TextStyle(
                            color: callNameColor(hollow,
                                isSelf: false, master: share.master)),
                      ),
                      const TextSpan(text: ' is sharing'),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.label
                        .copyWith(color: hollow.textPrimary),
                  ),
                  if (quality != null && quality.isNotEmpty)
                    Text(
                      callQualityText(quality),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textTertiary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            watch,
          ],
        ),
      ),
    );
  }
}

/// Your own share on the phone. It is never previewed (the phone would film
/// itself filming), so it says who is watching and offers Stop sharing.
class MobileOwnShare extends ConsumerWidget {
  final CallShare share;
  final VoidCallback? onStop;

  const MobileOwnShare({super.key, required this.share, required this.onStop});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final watchers = share.watchers;
    final who = switch (watchers.length) {
      0 => 'Nobody is watching yet',
      1 => '${displayNameFor(profiles, watchers.first)} is watching',
      _ => '${watchers.length} watching',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusLg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.md),
        child: Row(
          children: [
            Icon(LucideIcons.monitorUp, size: 20, color: hollow.accentText),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("You're sharing your screen",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.label
                          .copyWith(color: hollow.textPrimary)),
                  Text(who,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textTertiary)),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.outline(
              compact: true,
              onPressed: onStop,
              child: const Text('Stop sharing'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A watched share at the top of the phone's call screen: 16:9, its name and
/// Stop watching on it, Full screen in its corner. A tap opens it full screen
/// too, the way clicking a focused share does on the desktop.
class MobileLiveShare extends StatelessWidget {
  final CallShare share;
  final VoidCallback? onStopWatching;
  final Future<void> Function()? onRetryWatch;
  final VoidCallback? onFullscreen;

  const MobileLiveShare({
    super.key,
    required this.share,
    this.onStopWatching,
    this.onRetryWatch,
    this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final fullscreen = onFullscreen;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ShareTile(
            share: share,
            size: CallTileSize.large,
            onTap: fullscreen,
            onStopWatching: onStopWatching,
            onRetryWatch: onRetryWatch,
          ),
          // The share's own sound, where the desktop keeps it in More.
          Positioned(
            left: HollowSpacing.sm,
            bottom: HollowSpacing.sm,
            child: MobileScrimIconButton(
              icon: LucideIcons.volume2,
              label: 'Share volume',
              onTap: () => showShareVolumeSheet(context),
            ),
          ),
          if (fullscreen != null)
            Positioned(
              right: HollowSpacing.sm,
              bottom: HollowSpacing.sm,
              child: MobileScrimIconButton(
                icon: LucideIcons.maximize,
                label: 'Full screen',
                onTap: fullscreen,
              ),
            ),
        ],
      ),
    );
  }
}

/// An icon control laid over video: the media scrim, a white glyph.
class MobileScrimIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const MobileScrimIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      backgroundColor: HollowColors.mediaScrim,
      child: SizedBox.square(
        dimension: MobileCallMetrics.touch,
        child: Icon(icon, size: 20, color: HollowColors.onMedia),
      ),
    );
  }
}

/// The screen while you watch a share: the share on top, any other offers,
/// then everyone in a row of faces.
class MobileWatchingView extends StatelessWidget {
  final CallStageData data;
  final CallShare share;
  final String peopleTitle;
  final VoidCallback onFullscreen;

  const MobileWatchingView({
    super.key,
    required this.data,
    required this.share,
    required this.peopleTitle,
    required this.onFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final offers = [
      for (final s in data.shares)
        if (s.isOffer) s
    ];
    final mine = [
      for (final s in data.shares)
        if (s.isMine) s
    ];
    return ListView(
      padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
          child: MobileLiveShare(
            share: share,
            onStopWatching: () => data.onStopWatching(share.owner),
            onRetryWatch: data.onRetryWatch == null
                ? null
                : () => data.onRetryWatch!(share.owner),
            onFullscreen: onFullscreen,
          ),
        ),
        for (final s in [...offers, ...mine])
          Padding(
            padding: const EdgeInsets.fromLTRB(
                HollowSpacing.lg, HollowSpacing.md, HollowSpacing.lg, 0),
            child: s.isMine
                ? MobileOwnShare(share: s, onStop: data.onStopSharing)
                : MobileShareOffer(
                    share: s, onWatch: () => data.onWatch(s.owner)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.lg,
              HollowSpacing.md),
          child: Text(peopleTitle,
              style:
                  HollowTypography.label.copyWith(color: hollow.textPrimary)),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in data.people) ...[
                if (p != data.people.first)
                  const SizedBox(width: HollowSpacing.md),
                MobileCallFace(
                  key: ValueKey('watch-face-${p.id}'),
                  person: p,
                  size: MobileCallMetrics.watchAvatar,
                  nameStyle: HollowTypography.caption,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// The share to show while watching: the focused one when it is a live share
/// of someone else's, else the first one watched.
CallShare? watchedShareOf(CallStageData data) {
  final focus = data.focus;
  if (focus != null) {
    final focused = data.shareFor(focus);
    if (focused != null && focused.watched && !focused.isMine) return focused;
  }
  for (final s in data.shares) {
    if (s.watched && !s.isMine) return s;
  }
  return null;
}

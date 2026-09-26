import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:hollow/src/ui/shell/voice_quick_controls.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The DM call's name for the peer: your nickname for them, else theirs.
String dmCallPeerName(WidgetRef ref, String master) {
  final nick = ref.watch(localNicknameProvider.select((m) => m[master]));
  if (nick != null && nick.isNotEmpty) return nick;
  return displayNameForPeer(
      ref.watch(profileProvider.select((p) => p[master])), master);
}

/// The DM call is with [master]. Incoming calls carry the caller's DEVICE id
/// and outgoing ones the MASTER, so the compare goes through the resolver.
bool isDmCallWith(WidgetRef ref, CallState call, String master) =>
    call.status != CallStatus.idle &&
    call.peerId != null &&
    ref.watch(deviceLinkProvider).identityOf(call.peerId!) == master;

/// Something in the call needs the stage (D2): a camera on either side, or a
/// share being watched or sent. An unwatched offer does not.
bool dmStageForced(CallState call) =>
    call.isVideoEnabled ||
    call.remoteVideoEnabled ||
    call.isScreenSharing ||
    call.watchingRemoteShare;

/// The call id whose stage the user opened with "Open the call".
final dmStageOpenedProvider = StateProvider<String?>((_) => null);

/// Whether the DM with [master] shows the stage rather than the chat.
bool watchDmStageShown(WidgetRef ref, String master) {
  final call = ref.watch(callProvider.select((c) => (
        status: c.status,
        peerId: c.peerId,
        callId: c.callId,
        forced: dmStageForced(c),
      )));
  if (call.status != CallStatus.active && call.status != CallStatus.connecting) {
    return false;
  }
  if (call.peerId == null ||
      ref.watch(deviceLinkProvider).identityOf(call.peerId!) != master) {
    return false;
  }
  return call.forced || ref.watch(dmStageOpenedProvider) == call.callId;
}

/// Writes a resolved focus back after the frame, so a focus whose source
/// ended is not revived when that source comes back (D7).
void _normalizeFocus(BuildContext context, CallSourceId? requested,
    CallSourceId? effective, void Function(CallSourceId?) write) {
  if (requested == effective) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) write(effective);
  });
}

/// The DM call as stage data.
class DmCallStageSource extends CallStageSource {
  final String peerMaster;
  const DmCallStageSource(this.peerMaster);

  @override
  CallStageData? watchData(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    if (!isDmCallWith(ref, call, peerMaster)) return null;
    final calls = ref.read(callProvider.notifier);
    final voice = calls.voiceService;
    final me = ref.watch(identityProvider).peerId ?? '';
    final name = dmCallPeerName(ref, peerMaster);

    final shares = [
      if (call.remoteScreenSharing)
        CallShare(
          owner: peerMaster,
          master: peerMaster,
          isMine: false,
          name: name,
          watched: call.watchingRemoteShare,
          renderer: call.watchingRemoteShare ? calls.screenShareRenderer : null,
          quality: call.remoteScreenShareLabel,
        ),
      if (call.isScreenSharing)
        CallShare(
          owner: me,
          master: me,
          isMine: true,
          name: 'You',
          watched: true,
          renderer: calls.localScreenShareRenderer,
          quality: call.screenShareLabel,
          watchers: call.peerWatchingMyShare ? [peerMaster] : const [],
        ),
    ];

    final focusCtl = ref.read(focusedDmSourceProvider.notifier);
    final gridCtl = ref.read(dmShareGridViewProvider.notifier);
    void store(CallSourceId? source) {
      focusCtl.state = source == null
          ? const DmFocusedSource.none()
          : DmFocusedSource(
              peerId: source.owner,
              type: source.kind == CallSourceKind.camera ? 'camera' : 'screen',
            );
    }

    void focusOn(CallSourceId? source) {
      store(source);
      gridCtl.state = false;
    }

    final people = [
      CallPerson(
        id: me,
        master: me,
        isSelf: true,
        name: 'You',
        cameraOn: call.isVideoEnabled,
        camera: call.isVideoEnabled ? voice?.localRenderer : null,
        mirror: call.isFrontCamera,
        muted: call.isMuted,
        deafened: call.isDeafened,
        speaking: callSpeakingProvider.select((s) => s.local),
      ),
      CallPerson(
        id: peerMaster,
        master: peerMaster,
        isSelf: false,
        name: name,
        cameraOn: call.remoteVideoEnabled,
        camera: call.remoteVideoEnabled ? voice?.remoteRenderer : null,
        muted: call.remoteMuted,
        deafened: call.remoteDeafened,
        speaking: callSpeakingProvider.select((s) => s.remote),
        link: callLinkHealthProvider.select((s) => s.hasFlair ? s : null),
        onMenu: (menuContext, anchor) => showDmPeerMenu(
          menuContext,
          anchor,
          onFocus: call.remoteVideoEnabled
              ? () => focusOn(CallSourceId.camera(peerMaster))
              : null,
        ),
      ),
    ];

    final stored = ref.watch(focusedDmSourceProvider);
    final requested = stored.peerId == null
        ? null
        : CallSourceId(
            stored.peerId!,
            stored.type == 'camera'
                ? CallSourceKind.camera
                : CallSourceKind.screen,
          );
    final focus = resolveStageFocus(
      requested: requested,
      live: liveStageSources(shares: shares, people: people),
      liveShares: [for (final s in shares) if (s.watched) s.source],
    );
    _normalizeFocus(context, requested, focus, store);

    return CallStageData(
      people: people,
      shares: shares,
      focus: focus,
      gridOn: ref.watch(dmShareGridViewProvider),
      onFocus: focusOn,
      onGrid: (on) => gridCtl.state = on,
      onWatch: (_) {
        calls.watchRemoteScreenShare();
        focusOn(CallSourceId.screen(peerMaster));
      },
      onStopWatching: (_) => calls.stopWatchingRemoteScreenShare(),
      onRetryWatch: (_) async {
        await calls.stopWatchingRemoteScreenShare();
        await calls.watchRemoteScreenShare();
      },
      onStopSharing: () => calls.stopScreenShare(),
    );
  }

  @override
  CallBarModel? watchBar(
    BuildContext context,
    WidgetRef ref,
    CallStageData data, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
  }) {
    final call = ref.watch(callProvider);
    final calls = ref.read(callProvider.notifier);
    final active = call.status == CallStatus.active;
    final forced = dmStageForced(call);
    final layout = fullscreen || forced
        ? stageLayoutAction(data)
        : CallLayoutAction.backToChat;
    return CallBarModel(
      startedAt: active ? call.startedAt : null,
      muted: call.isMuted,
      deafened: call.isDeafened,
      onMute: calls.toggleMute,
      onDeafen: calls.toggleDeafen,
      cameraOn: call.isVideoEnabled,
      onCamera: active ? () => toggleCallCamera(context, dm: true) : null,
      sharing: call.isScreenSharing,
      onShare: callCanShareScreen && active
          ? () => toggleDmScreenShare(context, ref)
          : null,
      layout: layout,
      onLayout: layout == null
          ? null
          : () {
              if (layout == CallLayoutAction.backToChat) {
                ref.read(dmStageOpenedProvider.notifier).state = null;
              } else {
                applyStageLayout(data, layout);
              }
            },
      fullscreen: fullscreen,
      onFullscreen: FullscreenNotifier.supported ? onFullscreen : null,
      watching: call.watchingRemoteShare,
      leaveLabel: 'Leave the call',
      onLeave: () => leaveDmCall(context, ref),
    );
  }
}

/// The DM peer's menu on the stage: how loud they play, and Focus when their
/// camera is on.
void showDmPeerMenu(BuildContext context, Offset anchor,
    {VoidCallback? onFocus}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    builder: (_, _) => [
      const HollowMenuCustom(_DmVolumeRow()),
      if (onFocus != null) ...[
        const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.scanEye,
          label: 'Focus',
          onTap: onFocus,
        ),
      ],
    ],
  );
}

class _DmVolumeRow extends ConsumerStatefulWidget {
  const _DmVolumeRow();

  @override
  ConsumerState<_DmVolumeRow> createState() => _DmVolumeRowState();
}

class _DmVolumeRowState extends ConsumerState<_DmVolumeRow> {
  late double _volume = ref.read(callProvider.notifier).remoteVolume;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final inCall = ref.watch(
        callProvider.select((c) => c.status != CallStatus.idle));
    return Row(children: [
      Icon(LucideIcons.volume2, size: 14, color: hollow.textSecondary),
      Expanded(
        child: HollowSlider(
          value: _volume,
          min: 0,
          max: 2,
          label: '${(_volume * 100).round()}%',
          onChanged: inCall
              ? (value) {
                  setState(() => _volume = value);
                  ref
                      .read(callProvider.notifier)
                      .setRemoteVolume(value)
                      .catchError((Object _) {});
                }
              : null,
        ),
      ),
      const SizedBox(width: HollowSpacing.xs),
      Text('${(_volume * 100).round()}%',
          style:
              HollowTypography.caption.copyWith(color: hollow.textSecondary)),
    ]);
  }
}

/// A server voice room, or a meeting, as stage data.
class VcCallStageSource extends CallStageSource {
  final String serverId;
  final String channelId;

  const VcCallStageSource({required this.serverId, required this.channelId});

  bool get isConference => serverId.startsWith(conferenceServerId(''));

  @override
  CallStageData? watchData(BuildContext context, WidgetRef ref) {
    final vc = ref.watch(voiceChannelProvider);
    if (vc.currentServerId != serverId || vc.currentChannelId != channelId) {
      return null;
    }
    final notifier = ref.read(voiceChannelProvider.notifier);
    final links = ref.watch(deviceLinkProvider);
    final profiles = ref.watch(profileProvider);
    final me = ref.watch(identityProvider).peerId ?? '';
    final selfEntry = vc.selfParticipantId(
      serverId,
      channelId,
      master: me,
      device: ref.watch(localDevicePeerIdProvider).valueOrNull,
    );

    void focusOn(CallSourceId? source) {
      if (source == null) {
        notifier.clearFocus();
      } else {
        notifier.setFocusedSource(source.owner,
            source.kind == CallSourceKind.camera ? 'camera' : 'screen');
      }
      notifier.setGridView(false);
    }

    // Participants are DEVICE ids: tiles key by them, names and colours by
    // the master behind them. We are keyed by our master, as the provider's
    // own camera and share are.
    final people = <CallPerson>[
      CallPerson(
        id: me,
        master: me,
        isSelf: true,
        name: 'You',
        cameraOn: vc.isCameraOn,
        camera: vc.isCameraOn ? notifier.getCameraRenderer(me) : null,
        mirror: vc.isFrontCamera,
        muted: vc.isMuted,
        deafened: vc.isDeafened,
        speaking: vcLocalSpeakingProvider,
      ),
      for (final p in vc.getParticipants(serverId, channelId))
        if (p != selfEntry && p != me)
          _remote(ref, vc, notifier, p, links.identityOf(p),
              displayNameFor(profiles, links.identityOf(p)), focusOn),
    ];

    final shares = <CallShare>[
      for (final e in vc.peerScreenSharing.entries)
        if (e.value && e.key != me)
          CallShare(
            owner: e.key,
            master: links.identityOf(e.key),
            isMine: false,
            name: displayNameFor(profiles, links.identityOf(e.key)),
            watched: vc.watchingScreenShares.contains(e.key),
            renderer: vc.watchingScreenShares.contains(e.key)
                ? notifier.getScreenShareRenderer(e.key)
                : null,
            quality: vc.peerScreenShareLabels[e.key],
          ),
      if (vc.isScreenSharing)
        CallShare(
          owner: me,
          master: me,
          isMine: true,
          name: 'You',
          watched: true,
          renderer: notifier.localScreenShareRenderer,
          quality: vc.screenShareLabel,
          watchers: {for (final w in vc.shareWatchers) links.identityOf(w)}
              .toList(),
        ),
    ];

    final requestedOwner = vc.focusedScreenSharePeerId;
    final requested = requestedOwner == null
        ? null
        : CallSourceId(
            requestedOwner,
            vc.focusedSourceType == 'camera'
                ? CallSourceKind.camera
                : CallSourceKind.screen,
          );
    final focus = resolveStageFocus(
      requested: requested,
      live: liveStageSources(shares: shares, people: people),
      liveShares: [for (final s in shares) if (s.watched) s.source],
    );
    _normalizeFocus(context, requested, focus, (f) {
      if (f == null) {
        notifier.clearFocus();
      } else {
        notifier.setFocusedSource(
            f.owner, f.kind == CallSourceKind.camera ? 'camera' : 'screen');
      }
    });

    return CallStageData(
      people: people,
      shares: shares,
      focus: focus,
      gridOn: vc.isGridView,
      onFocus: focusOn,
      onGrid: notifier.setGridView,
      onWatch: (owner) => notifier.watchScreenShare(owner),
      onStopWatching: (owner) => notifier.stopWatchingScreenShare(owner),
      onRetryWatch: (owner) async {
        await notifier.stopWatchingScreenShare(owner);
        await notifier.watchScreenShare(owner);
      },
      onStopSharing: () => notifier.stopScreenShare(),
    );
  }

  CallPerson _remote(
    WidgetRef ref,
    VoiceChannelState vc,
    VoiceChannelNotifier notifier,
    String device,
    String master,
    String name,
    void Function(CallSourceId?) focusOn,
  ) {
    final audio = vc.getPeerAudioState(device);
    final cameraOn = vc.peerCameraOn[device] ?? false;
    return CallPerson(
      id: device,
      master: master,
      isSelf: false,
      name: name,
      cameraOn: cameraOn,
      camera: cameraOn ? notifier.getCameraRenderer(device) : null,
      muted: audio.isMuted,
      deafened: audio.isDeafened,
      speaking: vcSpeakingProvider.select((s) => s.contains(device)),
      link: vcLinkHealthProvider.select((m) => m[device]),
      onMenu: (menuContext, anchor) => showHollowMenu(
        context: menuContext,
        anchor: anchor,
        // menuRef watches, `ref` acts: rows run after the menu is gone.
        builder: (_, menuRef) => [
          if (cameraOn) ...[
            HollowMenuItem(
              icon: LucideIcons.scanEye,
              label: 'Focus',
              onTap: () => focusOn(CallSourceId.camera(device)),
            ),
            const HollowMenuDivider(),
          ],
          ...userMenuEntries(
            context: menuContext,
            menuRef: menuRef,
            ref: ref,
            peerId: master,
            anchor: anchor,
            serverId: isConference ? null : serverId,
            surface: UserMenuSurface.voice,
            routablePeerId: device,
          ),
        ],
      ),
    );
  }

  @override
  CallBarModel? watchBar(
    BuildContext context,
    WidgetRef ref,
    CallStageData data, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
  }) {
    final vc = ref.watch(voiceChannelProvider);
    final notifier = ref.read(voiceChannelProvider.notifier);
    final layout = stageLayoutAction(data);
    return CallBarModel(
      startedAt: vc.joinedAt,
      muted: vc.isMuted,
      deafened: vc.isDeafened,
      onMute: notifier.toggleMute,
      onDeafen: notifier.toggleDeafen,
      cameraOn: vc.isCameraOn,
      onCamera: () => toggleCallCamera(context, dm: false),
      sharing: vc.isScreenSharing,
      onShare: callCanShareScreen
          ? () => toggleVcScreenShare(context, ref)
          : null,
      layout: layout,
      onLayout: layout == null ? null : () => applyStageLayout(data, layout),
      fullscreen: fullscreen,
      onFullscreen: FullscreenNotifier.supported ? onFullscreen : null,
      watching: vc.isWatchingAnyShare,
      leaveLabel: isConference ? 'Leave the meeting' : 'Leave the room',
      onLeave: () => leaveVoiceRoom(context, ref),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/audio_route_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/speaking_border.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/share_volume_control.dart';
import 'package:hollow/src/ui/mobile/mobile_audio_route_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_screen_share_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_sheet_drag.dart';
import 'package:hollow/src/ui/mobile/mobile_source_switch_pill.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_avatars.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class MobileVoiceChannelRoute extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  const MobileVoiceChannelRoute({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
  });

  @override
  ConsumerState<MobileVoiceChannelRoute> createState() =>
      _MobileVoiceChannelRouteState();
}

class _MobileVoiceChannelRouteState
    extends ConsumerState<MobileVoiceChannelRoute> {
  Offset _pipOffset = const Offset(12, 12);
  bool _wakelockOn = false;

  @override
  void dispose() {
    if (_wakelockOn) {
      unawaited(WakelockPlus.disable().catchError((_) {}));
    }
    super.dispose();
  }

  // Earpiece proximity is global, in CallProximityController, so it works from
  // any screen.

  /// Keep the screen awake while video/screen share is displayed.
  void _syncWakelock(bool videoShown) {
    if (videoShown == _wakelockOn) return;
    _wakelockOn = videoShown;
    unawaited(WakelockPlus.toggle(enable: videoShown).catchError((_) {}));
  }

  // Session duration is a self-ticking leaf: a per-second setState here would
  // rebuild the entire Scaffold every second.

  bool _hasVideo(VoiceChannelState vcState) {
    // A SELF share does not count: mobile never previews its own share, so it
    // must not force an empty video view over the avatars. Only WATCHED remote
    // shares count (opt-in, issue #38).
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    for (final entry in vcState.peerScreenSharing.entries) {
      if (entry.value &&
          entry.key != localPeerId &&
          vcState.watchingScreenShares.contains(entry.key)) {
        return true;
      }
    }
    if (vcState.isCameraOn) return true;
    for (final entry in vcState.peerCameraOn.entries) {
      if (entry.value) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    // Pops when leaving this voice channel or switching to another.
    ref.listen<VoiceChannelState>(voiceChannelProvider, (prev, next) {
      if (prev == null) return;
      final wasIn = prev.currentServerId == widget.serverId &&
          prev.currentChannelId == widget.channelId;
      final isIn = next.currentServerId == widget.serverId &&
          next.currentChannelId == widget.channelId;
      if (wasIn && !isIn) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }
    });

    final notInChannel = vcState.currentServerId != widget.serverId ||
        vcState.currentChannelId != widget.channelId;

    if (notInChannel) {
      return Scaffold(
        backgroundColor: hollow.background,
        body: SafeArea(
          child: Center(
            child: Text(
              'Not connected',
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
            ),
          ),
        ),
      );
    }

    final hasVideo = _hasVideo(vcState);
    _syncWakelock(hasVideo);

    // The watched share displayed full-bleed, for Stop watching.
    final watchedSharers = <String>[
      for (final e in vcState.peerScreenSharing.entries)
        if (e.value &&
            e.key != localPeerId &&
            vcState.watchingScreenShares.contains(e.key))
          e.key,
    ];
    final displayedSharer =
        watchedSharers.contains(vcState.focusedScreenSharePeerId)
            ? vcState.focusedScreenSharePeerId
            : (watchedSharers.isEmpty ? null : watchedSharers.first);

    return MobileSheetDragToMinimize(
      child: Scaffold(
        backgroundColor: hollow.background,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(hollow, vcState.joinedAt,
                  remoteSharing: vcState.isWatchingAnyShare,
                  watchedSharerId: displayedSharer),
              // Surfaces maintenance and outages while you are in a call.
              const SystemStatusBanner(),
              Expanded(
                child: hasVideo
                    ? _buildVideoView(hollow, vcState, localPeerId)
                    : _buildAudioView(hollow, vcState, localPeerId),
              ),
              _buildControls(hollow, vcState),
              const SizedBox(height: HollowSpacing.lg),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(HollowTheme hollow, DateTime? joinedAt,
      {required bool remoteSharing, String? watchedSharerId}) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          HollowPressable(
            semanticLabel: 'Minimize',
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.chevronDown,
                size: 24, color: hollow.textPrimary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '# ${widget.channelName}',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                CallDurationText(
                  startedAt: joinedAt ?? DateTime.now(),
                  style: HollowTypography.caption.copyWith(
                    color: hollow.success,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          // Opt-in watching, issue #38.
          if (watchedSharerId != null)
            HollowPressable(
              semanticLabel: 'Stop watching screen share',
              onTap: () => ref
                  .read(voiceChannelProvider.notifier)
                  .stopWatchingScreenShare(watchedSharerId),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.sm),
              child: Icon(LucideIcons.eyeOff,
                  size: 22, color: hollow.textPrimary),
            ),
          // In the top bar, because the controls row is already crowded.
          if (remoteSharing)
            const ShareVolumeButton(
              iconSize: 22,
              padding: EdgeInsets.all(HollowSpacing.sm),
            ),
        ],
      ),
    );
  }

  Widget _buildAudioView(
      HollowTheme hollow, VoiceChannelState vcState, String localPeerId) {
    // Self lives in this set under the ROUTABLE DEVICE id, never the master, so
    // `contains(localPeerId)` is false on every install where device != master
    // and an unconditional insert renders "You" twice.
    final myDevice = ref.watch(localDevicePeerIdProvider).valueOrNull;
    final participants =
        vcState.getParticipants(widget.serverId, widget.channelId).toList();
    final selfInList = vcState.selfParticipantId(
      widget.serverId,
      widget.channelId,
      master: localPeerId,
      device: myDevice,
    );
    if (selfInList == null) {
      participants.insert(0, localPeerId);
    }
    // The id form the rows below key US by.
    final selfId = selfInList ?? localPeerId;

    final mutedSet = <String>{};
    final deafenedSet = <String>{};
    for (final p in participants) {
      if (p == selfId) {
        if (vcState.isMuted) mutedSet.add(p);
        if (vcState.isDeafened) deafenedSet.add(p);
      } else {
        final audio = vcState.getPeerAudioState(p);
        if (audio.isMuted) mutedSet.add(p);
        if (audio.isDeafened) deafenedSet.add(p);
      }
    }

    // Unwatched shares are "Watch" chips over the avatar view, never a forced
    // video surface (opt-in, issue #38).
    final unwatched = [
      for (final p in vcState.unwatchedRemoteShares)
        if (p != localPeerId) p,
    ];

    // Scoped so a VAD flip rebuilds only the avatar cluster, not the Scaffold.
    final avatars = Center(
      child: Consumer(builder: (context, ref, _) {
        // Self comes from the local flag, re-keyed under the id THIS list uses.
        final speakingSet = {
          ...ref.watch(vcSpeakingProvider),
          if (ref.watch(vcLocalSpeakingProvider)) selfId,
        };
        return MobileClusteredAvatars(
          participants: participants,
          speakingSet: speakingSet,
          mutedSet: mutedSet,
          deafenedSet: deafenedSet,
        );
      }),
    );
    if (unwatched.isEmpty) return avatars;

    final profiles = ref.watch(profileProvider);
    return Column(
      children: [
        const SizedBox(height: HollowSpacing.sm),
        for (final peerId in unwatched)
          Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
            child: Builder(builder: (context) {
              final displayId =
                  ref.watch(deviceLinkProvider).identityOf(peerId);
              final name = displayNameFor(profiles, displayId);
              return HollowPressable(
                onTap: () => ref
                    .read(voiceChannelProvider.notifier)
                    .watchScreenShare(peerId),
                semanticLabel: 'Watch screen share from $name',
                borderRadius: BorderRadius.circular(HollowRadius.pill),
                backgroundColor: hollow.surface,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md,
                  vertical: HollowSpacing.xs,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.monitor,
                        size: 14, color: hollow.accentText),
                    const SizedBox(width: HollowSpacing.xs),
                    Text(
                      '$name is sharing. Watch',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        Expanded(child: avatars),
      ],
    );
  }

  Widget _buildVideoView(
      HollowTheme hollow, VoiceChannelState vcState, String localPeerId) {
    final vcNotifier = ref.read(voiceChannelProvider.notifier);

    // A SELF share is deliberately not previewed: the phone shares its own
    // screen, so the preview would be an infinite mirror. Only WATCHED shares
    // render (opt-in, issue #38).
    final allRemoteSharers = <String>[
      for (final e in vcState.peerScreenSharing.entries)
        if (e.value && e.key != localPeerId) e.key,
    ];
    final remoteSharers = <String>[
      for (final p in allRemoteSharers)
        if (vcState.watchingScreenShares.contains(p)) p,
    ];
    final unwatchedSharers = {
      for (final p in allRemoteSharers)
        if (!vcState.watchingScreenShares.contains(p)) p,
    };

    // Only shown in mixed mode: a camera-only grid already shows every camera
    // at once.
    final sources = <({String peerId, String type})>[
      for (final p in allRemoteSharers) (peerId: p, type: 'screen'),
      if (vcState.isCameraOn) (peerId: localPeerId, type: 'camera'),
      for (final e in vcState.peerCameraOn.entries)
        if (e.value && e.key != localPeerId)
          (peerId: e.key, type: 'camera'),
    ];
    final showPill = allRemoteSharers.isNotEmpty && sources.length > 1;

    final focusedPeer = vcState.focusedScreenSharePeerId;
    final focusedType = vcState.focusedSourceType;

    Widget? content;
    String? effectivePeer;
    String? effectiveType;

    // Explicit camera focus in mixed mode: that camera full-bleed.
    if (remoteSharers.isNotEmpty &&
        focusedType == 'camera' &&
        focusedPeer != null) {
      final isLocal = focusedPeer == localPeerId;
      final camOn = isLocal
          ? vcState.isCameraOn
          : (vcState.peerCameraOn[focusedPeer] ?? false);
      final renderer =
          camOn ? vcNotifier.getCameraRenderer(focusedPeer) : null;
      if (renderer != null) {
        content = Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: RTCVideoView(
                  renderer,
                  mirror: isLocal && vcState.isFrontCamera,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
            if (vcState.isCameraOn && !isLocal)
              _buildLocalPip(
                  hollow, vcNotifier.getCameraRenderer(localPeerId)),
          ],
        );
        effectivePeer = focusedPeer;
        effectiveType = 'camera';
      }
    }

    // Remote screen share, full-bleed.
    if (content == null && remoteSharers.isNotEmpty) {
      final screenPeer = remoteSharers.contains(focusedPeer)
          ? focusedPeer!
          : remoteSharers.first;
      final renderer = vcNotifier.getScreenShareRenderer(screenPeer);
      if (renderer != null) {
        content = Stack(
          children: [
            Positioned.fill(
              // Pinch-zoom and pan, for reading a desktop screen on a phone.
              child: InteractiveViewer(
                maxScale: 6,
                child: RepaintBoundary(
                  child: RTCVideoView(
                    renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                ),
              ),
            ),
            if (vcState.isCameraOn)
              _buildLocalPip(
                  hollow, vcNotifier.getCameraRenderer(localPeerId)),
          ],
        );
        effectivePeer = screenPeer;
        effectiveType = 'screen';
      }
    }

    if (content != null) {
      if (!showPill) return content;
      return Stack(
        children: [
          Positioned.fill(child: content),
          Positioned(
            top: HollowSpacing.sm,
            left: 0,
            right: 0,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md),
                child: MobileSourceSwitchPill(
                  sources: sources,
                  focusedPeerId: effectivePeer,
                  focusedType: effectiveType,
                  localPeerId: localPeerId,
                  unwatchedPeerIds: unwatchedSharers,
                  onSelect: (peerId, type) {
                    // Tapping an unwatched tab opts in (issue #38).
                    if (type == 'screen' &&
                        unwatchedSharers.contains(peerId)) {
                      vcNotifier.watchScreenShare(peerId);
                    } else {
                      vcNotifier.setFocusedSource(peerId, type);
                    }
                  },
                ),
              ),
            ),
          ),
        ],
      );
    }

    final cameraPeers = <String>[];
    if (vcState.isCameraOn) cameraPeers.add(localPeerId);
    for (final entry in vcState.peerCameraOn.entries) {
      if (entry.value && entry.key != localPeerId) {
        cameraPeers.add(entry.key);
      }
    }

    if (cameraPeers.length == 1 && cameraPeers.first == localPeerId) {
      final localRenderer = vcNotifier.getCameraRenderer(localPeerId);
      if (localRenderer != null) {
        return RepaintBoundary(
          child: RTCVideoView(
            localRenderer,
            mirror: vcState.isFrontCamera,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
        );
      }
    }

    if (cameraPeers.length == 1) {
      final renderer = vcNotifier.getCameraRenderer(cameraPeers.first);
      if (renderer != null) {
        return Stack(
          children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: RTCVideoView(
                  renderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
            if (vcState.isCameraOn)
              _buildLocalPip(
                  hollow, vcNotifier.getCameraRenderer(localPeerId)),
          ],
        );
      }
    }

    return Padding(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cols = cameraPeers.length <= 2 ? 1 : 2;
          final rows = (cameraPeers.length / cols).ceil();
          final tileW = constraints.maxWidth / cols - HollowSpacing.xs;
          final tileH = constraints.maxHeight / rows - HollowSpacing.xs;

          return Wrap(
            spacing: HollowSpacing.xs,
            runSpacing: HollowSpacing.xs,
            children: cameraPeers.map((peerId) {
              final renderer = vcNotifier.getCameraRenderer(peerId);
              final isLocal = peerId == localPeerId;
              return SizedBox(
                width: tileW,
                height: tileH,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      renderer != null
                          ? RepaintBoundary(
                              child: RTCVideoView(
                                renderer,
                                mirror: isLocal && vcState.isFrontCamera,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitCover,
                              ),
                            )
                          : Container(color: hollow.surface),
                      // Self reads the local flag, never the participant set;
                      // see [vcLocalSpeakingProvider].
                      Consumer(builder: (context, ref, _) {
                        final speaking = isLocal
                            ? ref.watch(vcLocalSpeakingProvider)
                            : ref.watch(vcSpeakingProvider
                                .select((s) => s.contains(peerId)));
                        return SpeakingRing(
                          isSpeaking: speaking,
                          borderRadius:
                              BorderRadius.circular(hollow.radiusMd),
                        );
                      }),
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  Widget _buildLocalPip(HollowTheme hollow, RTCVideoRenderer? renderer) {
    if (renderer == null) return const SizedBox.shrink();
    final screenWidth = MediaQuery.of(context).size.width;

    return Positioned(
      right: _pipOffset.dx,
      bottom: _pipOffset.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final maxDy = MediaQuery.sizeOf(context).height - 260.0;
            _pipOffset = Offset(
              (_pipOffset.dx - details.delta.dx).clamp(0.0, screenWidth - 110),
              (_pipOffset.dy - details.delta.dy).clamp(0.0, maxDy),
            );
          });
        },
        child: Container(
          width: 90,
          height: 120,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: hollow.border, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: RepaintBoundary(
              child: RTCVideoView(
                renderer,
                mirror: ref.watch(voiceChannelProvider
                    .select((s) => s.isFrontCamera)),
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleScreenShareToggle(VoiceChannelState vcState) async {
    final vcNotifier = ref.read(voiceChannelProvider.notifier);
    if (vcState.isScreenSharing) {
      await vcNotifier.stopScreenShare();
      return;
    }
    final choice = await showMobileScreenShareSheet(context);
    if (choice == null || !mounted) return;
    // Android ignores these constraints and captures at native display size;
    // the per-peer encoder cap does the actual downscaling.
    await vcNotifier.startScreenShare(
      'screen',
      1080,
      1920,
      30,
      shareAudio: choice.shareAudio,
    );
  }

  /// Speaker button that doubles as the audio-device picker once a headset is
  /// attached. The icon shows where audio ACTUALLY is, so a headset user can
  /// see the channel is not stuck on the phone.
  Widget _buildAudioRouteButton(
    HollowTheme hollow, {
    required double iconSize,
    required double buttonSize,
    required bool handsFree,
  }) {
    final routeState = ref.watch(audioRouteProvider);
    final activeRoute = routeState.activeRoute;

    Future<void> openSheet() => showMobileAudioRouteSheet(
          context,
          onSelect: (route) =>
              ref.read(voiceChannelProvider.notifier).selectAudioRoute(route),
        );

    return MobileControlButton(
      icon: audioRouteIcon(routeState.activeKind),
      iconSize: iconSize,
      size: buttonSize,
      color: handsFree ? hollow.accent : hollow.textPrimary,
      backgroundColor:
          handsFree ? hollow.accent.withValues(alpha: 0.15) : hollow.elevated,
      semanticLabel: activeRoute == null
          ? 'Speaker'
          : 'Audio device: ${activeRoute.label}',
      onTap: routeState.hasExternalRoute
          ? openSheet
          : () => ref.read(voiceChannelProvider.notifier).toggleSpeaker(),
      onLongPress: openSheet,
    );
  }

  Widget _buildControls(HollowTheme hollow, VoiceChannelState vcState) {
    final vcNotifier = ref.read(voiceChannelProvider.notifier);
    final isMobile = Platform.isAndroid || Platform.isIOS;
    // Six buttons overflow a narrow phone at 56px.
    final buttonCount =
        4 + (isMobile ? 2 : 0) + (isMobile && vcState.isCameraOn ? 1 : 0);
    final buttonSize = buttonCount >= 6 ? 46.0 : 56.0;
    final iconSize = buttonCount >= 6 ? 21.0 : 26.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          MobileControlButton(
            icon: vcState.isMuted ? LucideIcons.micOff : LucideIcons.mic,
            iconSize: iconSize,
            size: buttonSize,
            color: vcState.isMuted ? hollow.error : hollow.textPrimary,
            backgroundColor: vcState.isMuted
                ? hollow.error.withValues(alpha: 0.15)
                : hollow.elevated,
            semanticLabel: vcState.isMuted ? 'Unmute' : 'Mute',
            onTap: () => vcNotifier.toggleMute(),
          ),
          MobileControlButton(
            icon: LucideIcons.headphones,
            iconSize: iconSize,
            size: buttonSize,
            color: vcState.isDeafened ? hollow.error : hollow.textPrimary,
            backgroundColor: vcState.isDeafened
                ? hollow.error.withValues(alpha: 0.15)
                : hollow.elevated,
            semanticLabel: vcState.isDeafened ? 'Undeafen' : 'Deafen',
            onTap: () => vcNotifier.toggleDeafen(),
          ),
          if (isMobile)
            _buildAudioRouteButton(
              hollow,
              iconSize: iconSize,
              buttonSize: buttonSize,
              handsFree: vcState.isSpeakerOn,
            ),
          MobileControlButton(
            icon: vcState.isCameraOn
                ? LucideIcons.video
                : LucideIcons.videoOff,
            iconSize: iconSize,
            size: buttonSize,
            color: vcState.isCameraOn ? hollow.accent : hollow.textPrimary,
            backgroundColor: vcState.isCameraOn
                ? hollow.accent.withValues(alpha: 0.15)
                : hollow.elevated,
            semanticLabel: vcState.isCameraOn
                ? 'Turn off camera'
                : 'Turn on camera',
            onTap: () => vcNotifier.toggleCamera(),
          ),
          if (isMobile)
            MobileControlButton(
              icon: vcState.isScreenSharing
                  ? LucideIcons.monitorOff
                  : LucideIcons.monitor,
              iconSize: iconSize,
              size: buttonSize,
              color: vcState.isScreenSharing
                  ? hollow.accent
                  : hollow.textPrimary,
              backgroundColor: vcState.isScreenSharing
                  ? hollow.accent.withValues(alpha: 0.15)
                  : hollow.elevated,
              semanticLabel: vcState.isScreenSharing
                  ? 'Stop sharing screen'
                  : 'Share screen',
              onTap: () => _handleScreenShareToggle(vcState),
            ),
          if (isMobile && vcState.isCameraOn)
            MobileControlButton(
              icon: LucideIcons.switchCamera,
              iconSize: iconSize,
              size: buttonSize,
              color: hollow.textPrimary,
              backgroundColor: hollow.elevated,
              semanticLabel: 'Flip camera',
              onTap: () => vcNotifier.switchCamera(),
            ),
          MobileControlButton(
            icon: LucideIcons.phoneOff,
            iconSize: iconSize,
            size: buttonSize,
            color: Colors.white,
            backgroundColor: hollow.error,
            semanticLabel: 'Leave call',
            onTap: () {
              vcNotifier.leaveChannel();
            },
          ),
        ],
      ),
    );
  }
}

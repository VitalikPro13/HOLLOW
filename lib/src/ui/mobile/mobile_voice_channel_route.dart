import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/mobile/mobile_screen_share_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_sheet_drag.dart';
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

  // Earpiece proximity (blank-on-ear-hold) is handled globally by
  // CallProximityController so it works from any screen, not just here.

  /// Keep the screen awake while video/screen share is displayed.
  void _syncWakelock(bool videoShown) {
    if (videoShown == _wakelockOn) return;
    _wakelockOn = videoShown;
    unawaited(WakelockPlus.toggle(enable: videoShown).catchError((_) {}));
  }

  // Session duration is rendered by CallDurationText (self-ticking leaf) —
  // the old per-second setState rebuilt this ENTIRE Scaffold every second.

  bool _hasVideo(VoiceChannelState vcState) {
    // A SELF share focus doesn't count — mobile never previews its own share
    // (mirror recursion; see _buildVideoView), so it must not force an empty
    // video view over the avatars.
    final localPeerId = ref.read(identityProvider).peerId ?? '';
    final screenPeer = vcState.focusedScreenSharePeerId;
    if (screenPeer != null && screenPeer != localPeerId) return true;
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

    // Auto-pop when leaving the voice channel or switching to a different one.
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

    return MobileSheetDragToMinimize(
      child: Scaffold(
        backgroundColor: hollow.background,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(hollow, vcState.joinedAt),
              // System-status notice, at the top under the channel name (divider
              // below) — surfaces maintenance/outage while you're in a call.
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

  Widget _buildTopBar(HollowTheme hollow, DateTime? joinedAt) {
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
        ],
      ),
    );
  }

  Widget _buildAudioView(
      HollowTheme hollow, VoiceChannelState vcState, String localPeerId) {
    final participants =
        vcState.getParticipants(widget.serverId, widget.channelId).toList();
    if (!participants.contains(localPeerId)) {
      participants.insert(0, localPeerId);
    }

    final mutedSet = <String>{};
    final deafenedSet = <String>{};
    for (final p in participants) {
      if (p == localPeerId) {
        if (vcState.isMuted) mutedSet.add(p);
        if (vcState.isDeafened) deafenedSet.add(p);
      } else {
        final audio = vcState.getPeerAudioState(p);
        if (audio.isMuted) mutedSet.add(p);
        if (audio.isDeafened) deafenedSet.add(p);
      }
    }

    // Speaking state via a scoped Consumer: VAD flips rebuild ONLY the avatar
    // cluster, never this whole voice-channel Scaffold.
    return Center(
      child: Consumer(builder: (context, ref, _) {
        final speakingSet = ref.watch(vcSpeakingProvider);
        return MobileClusteredAvatars(
          participants: participants,
          speakingSet: speakingSet,
          mutedSet: mutedSet,
          deafenedSet: deafenedSet,
        );
      }),
    );
  }

  Widget _buildVideoView(
      HollowTheme hollow, VoiceChannelState vcState, String localPeerId) {
    final vcNotifier = ref.read(voiceChannelProvider.notifier);

    // Remote screen share takes priority. A SELF share is deliberately not
    // previewed on mobile: the phone shares its own screen, so a preview
    // would show the app showing itself (infinite mirror) — the avatar view
    // + the accent share button convey the sharing state instead.
    final screenPeer = vcState.focusedScreenSharePeerId;
    if (screenPeer != null && screenPeer != localPeerId) {
      final renderer = vcNotifier.getScreenShareRenderer(screenPeer);
      if (renderer != null) {
        return Stack(
          children: [
            Positioned.fill(
              // Pinch-zoom + pan for reading a desktop screen on a phone.
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
            // Local camera PiP if on.
            if (vcState.isCameraOn)
              _buildLocalPip(hollow, vcNotifier.getCameraRenderer(localPeerId)),
          ],
        );
      }
    }

    // Camera grid.
    final cameraPeers = <String>[];
    if (vcState.isCameraOn) cameraPeers.add(localPeerId);
    for (final entry in vcState.peerCameraOn.entries) {
      if (entry.value && entry.key != localPeerId) {
        cameraPeers.add(entry.key);
      }
    }

    if (cameraPeers.length == 1 && cameraPeers.first == localPeerId) {
      // Only local camera — full self-view.
      final localRenderer = vcNotifier.getCameraRenderer(localPeerId);
      if (localRenderer != null) {
        return RepaintBoundary(
          child: RTCVideoView(
            localRenderer,
            mirror: true,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
        );
      }
    }

    if (cameraPeers.length == 1) {
      // Only one remote camera.
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

    // Multi-camera grid.
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
                  child: renderer != null
                      ? RepaintBoundary(
                          child: RTCVideoView(
                            renderer,
                            mirror: isLocal,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          ),
                        )
                      : Container(color: hollow.surface),
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
                mirror: true,
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
    // Portrait phone capture: cap the long edge at 1920 (1080p-class).
    // Android ignores the constraints and captures at native display size;
    // the per-peer encoder cap does the actual downscaling.
    await vcNotifier.startScreenShare(
      'screen',
      1080,
      1920,
      30,
      shareAudio: choice.shareAudio,
    );
  }

  Widget _buildControls(HollowTheme hollow, VoiceChannelState vcState) {
    final vcNotifier = ref.read(voiceChannelProvider.notifier);
    final isMobile = Platform.isAndroid || Platform.isIOS;
    // 6+ buttons (speaker + share + flip camera visible) overflow narrow
    // phones at 56px — shrink when crowded.
    final buttonCount =
        4 + (isMobile ? 2 : 0) + (isMobile && vcState.isCameraOn ? 1 : 0);
    final buttonSize = buttonCount >= 6 ? 46.0 : 56.0;
    final iconSize = buttonCount >= 6 ? 21.0 : 26.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Mute
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
          // Deafen
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
          // Speakerphone (mobile only)
          if (isMobile)
            MobileControlButton(
              icon: LucideIcons.speaker,
              iconSize: iconSize,
              size: buttonSize,
              color:
                  vcState.isSpeakerOn ? hollow.accent : hollow.textPrimary,
              backgroundColor: vcState.isSpeakerOn
                  ? hollow.accent.withValues(alpha: 0.15)
                  : hollow.elevated,
              semanticLabel: 'Speaker',
              onTap: () => vcNotifier.toggleSpeaker(),
            ),
          // Camera
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
          // Share screen (mobile only)
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
          // Flip camera (mobile only, when camera is on)
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
          // Leave (red)
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

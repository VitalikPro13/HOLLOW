import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:proximity_sensor/proximity_sensor.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_avatars.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';


/// Full-screen call overlay that slides up from the bottom inside a DM chat.
/// Handles all call states: ringing, connecting, active (audio + video).
class MobileCallScreen extends ConsumerStatefulWidget {
  final String peerId;
  const MobileCallScreen({super.key, required this.peerId});

  @override
  ConsumerState<MobileCallScreen> createState() => _MobileCallScreenState();
}

class _MobileCallScreenState extends ConsumerState<MobileCallScreen> {
  Timer? _durationTimer;
  Duration _duration = Duration.zero;
  Offset _pipOffset = const Offset(12, 12);
  StreamSubscription<int>? _proximitySub;
  bool _wakelockOn = false;

  @override
  void dispose() {
    _durationTimer?.cancel();
    _disableProximity();
    if (_wakelockOn) {
      unawaited(WakelockPlus.disable().catchError((_) {}));
    }
    super.dispose();
  }

  /// Keep the screen awake while video is displayed.
  void _syncWakelock(bool videoShown) {
    if (videoShown == _wakelockOn) return;
    _wakelockOn = videoShown;
    unawaited(WakelockPlus.toggle(enable: videoShown).catchError((_) {}));
  }

  static bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  /// Blank the screen when the phone is held to the ear — but only while
  /// audio actually plays through the earpiece (no speaker, no video).
  void _syncProximity(CallState call) {
    if (!_isMobilePlatform) return;
    final earpieceMode = call.status == CallStatus.active &&
        !call.isSpeakerOn &&
        !call.isVideoEnabled &&
        !call.remoteVideoEnabled;
    if (earpieceMode && _proximitySub == null) {
      // Android: explicit wake-lock-backed screen-off. iOS blanks natively
      // while the events stream is subscribed (proximityMonitoringEnabled).
      unawaited(
          ProximitySensor.setProximityScreenOff(true).catchError((_) => false));
      _proximitySub = ProximitySensor.events.listen((_) {}, onError: (_) {});
    } else if (!earpieceMode && _proximitySub != null) {
      _disableProximity();
    }
  }

  void _disableProximity() {
    if (_proximitySub == null) return;
    _proximitySub?.cancel();
    _proximitySub = null;
    unawaited(
        ProximitySensor.setProximityScreenOff(false).catchError((_) => false));
  }

  void _startTimer(DateTime startedAt) {
    _durationTimer?.cancel();
    _duration = DateTime.now().difference(startedAt);
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _duration = DateTime.now().difference(startedAt);
      });
    });
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _statusText(CallState call) {
    switch (call.status) {
      case CallStatus.ringing:
        return call.direction == CallDirection.outgoing
            ? 'Calling...'
            : 'Incoming...';
      case CallStatus.connecting:
        return 'Connecting...';
      case CallStatus.active:
        return _formatDuration(_duration);
      case CallStatus.idle:
        return 'Ended';
    }
  }

  /// Whether to show the video area. Must have an active call with explicit
  /// video enabled AND a real renderer with a source — otherwise the
  /// onRemoteVideoTrack safety net can trigger a black rectangle over the
  /// avatars even when no camera is actually sending.
  bool _hasRealVideo(CallState call) {
    if (call.status != CallStatus.active) return false;
    final notifier = ref.read(callProvider.notifier);
    final vs = notifier.voiceService;

    final screen = notifier.screenShareRenderer;
    final remoteHasScreen = call.remoteScreenSharing &&
        screen != null &&
        screen.srcObject != null;
    final remoteHasVideo = call.remoteVideoEnabled &&
        vs?.remoteRenderer != null &&
        vs!.remoteRenderer!.srcObject != null;
    final localHasVideo = call.isVideoEnabled &&
        vs?.localRenderer != null &&
        vs!.localRenderer!.srcObject != null;

    return remoteHasScreen || remoteHasVideo || localHasVideo;
  }

  @override
  Widget build(BuildContext context) {
    final call = ref.watch(callProvider);
    final hollow = HollowTheme.of(context);
    final localPeerId = ref.read(identityProvider).peerId ?? '';

    // Auto-pop when call ends.
    ref.listen<CallState>(callProvider, (prev, next) {
      if (next.status == CallStatus.idle &&
          prev?.status != CallStatus.idle) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      }
    });

    if (call.status == CallStatus.active && call.startedAt != null) {
      if (_durationTimer == null) _startTimer(call.startedAt!);
    } else if (call.status != CallStatus.active) {
      _durationTimer?.cancel();
      _durationTimer = null;
    }

    _syncProximity(call);

    final showVideo = _hasRealVideo(call);
    _syncWakelock(showVideo);

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(hollow, call),
            Expanded(
              child: showVideo
                  ? _buildVideoView(hollow, call)
                  : _buildAudioView(hollow, call, localPeerId),
            ),
            _buildControls(hollow, call),
            const SizedBox(height: HollowSpacing.lg),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(HollowTheme hollow, CallState call) {
    final profiles = ref.watch(profileProvider);
    final displayName = displayNameFor(profiles, widget.peerId);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          HollowPressable(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Icon(LucideIcons.chevronDown,
                size: 24, color: hollow.textPrimary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _statusText(call),
                  style: HollowTypography.caption.copyWith(
                    color: call.status == CallStatus.active
                        ? hollow.textSecondary
                        : hollow.accent,
                    fontFeatures: [const FontFeature.tabularFigures()],
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
      HollowTheme hollow, CallState call, String localPeerId) {
    return Center(
      child: MobileClusteredAvatars(
        participants: [localPeerId, widget.peerId],
        speakingSet: {
          if (call.isLocalSpeaking) localPeerId,
          if (call.isRemoteSpeaking) widget.peerId,
        },
        mutedSet: {
          if (call.isMuted) localPeerId,
          if (call.remoteMuted) widget.peerId,
        },
        deafenedSet: {
          if (call.isDeafened) localPeerId,
          if (call.remoteDeafened) widget.peerId,
        },
      ),
    );
  }

  Widget _buildVideoView(HollowTheme hollow, CallState call) {
    final notifier = ref.read(callProvider.notifier);
    final voiceService = notifier.voiceService;
    final remoteRenderer = voiceService?.remoteRenderer;
    final localRenderer = voiceService?.localRenderer;
    final screenRenderer = notifier.screenShareRenderer;
    final screenWidth = MediaQuery.sizeOf(context).width;

    // Incoming screen share takes priority over camera feeds.
    final showScreen = call.remoteScreenSharing &&
        screenRenderer != null &&
        screenRenderer.srcObject != null;
    final showRemoteFull = !showScreen &&
        call.remoteVideoEnabled &&
        remoteRenderer != null &&
        remoteRenderer.srcObject != null;
    final showLocalFull = !showScreen &&
        !showRemoteFull &&
        call.isVideoEnabled &&
        localRenderer != null &&
        localRenderer.srcObject != null;
    final showLocalPip = (showScreen || showRemoteFull) &&
        call.isVideoEnabled &&
        localRenderer != null &&
        localRenderer.srcObject != null;

    return Stack(
      children: [
        if (showScreen)
          Positioned.fill(
            // Pinch-zoom + pan for reading a desktop screen on a phone.
            child: InteractiveViewer(
              maxScale: 6,
              child: RepaintBoundary(
                child: RTCVideoView(
                  screenRenderer,
                  objectFit:
                      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
          )
        else if (showRemoteFull)
          Positioned.fill(
            child: RepaintBoundary(
              child: RTCVideoView(
                remoteRenderer,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
          )
        else if (showLocalFull)
          Positioned.fill(
            child: RepaintBoundary(
              child: RTCVideoView(
                localRenderer,
                mirror: true,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
          )
        else
          Positioned.fill(
            child: Container(
              color: hollow.elevated,
              child: Center(
                child: HollowAvatar(peerId: widget.peerId, size: 80),
              ),
            ),
          ),
        // Local PiP — portrait proportioned (3:4)
        if (showLocalPip)
          Positioned(
            right: _pipOffset.dx,
            bottom: _pipOffset.dy,
            child: GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  final maxDy = MediaQuery.sizeOf(context).height - 260.0;
                  _pipOffset = Offset(
                    (_pipOffset.dx - details.delta.dx)
                        .clamp(0.0, screenWidth - 110.0),
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
                      localRenderer,
                      mirror: true,
                      objectFit: RTCVideoViewObjectFit
                          .RTCVideoViewObjectFitCover,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildControls(HollowTheme hollow, CallState call) {
    const iconSize = 26.0;
    const buttonSize = 56.0;
    final canControl = call.status == CallStatus.active ||
        call.status == CallStatus.connecting;

    // Same button order as the voice channel screen:
    // mute, deafen, speaker, camera, hang up.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          MobileControlButton(
            icon: call.isMuted ? LucideIcons.micOff : LucideIcons.mic,
            iconSize: iconSize,
            size: buttonSize,
            color: call.isMuted ? hollow.error : hollow.textPrimary,
            backgroundColor: call.isMuted
                ? hollow.error.withValues(alpha: 0.15)
                : hollow.elevated,
            onTap: canControl
                ? () => ref.read(callProvider.notifier).toggleMute()
                : null,
          ),
          MobileControlButton(
            icon: LucideIcons.headphones,
            iconSize: iconSize,
            size: buttonSize,
            color: call.isDeafened ? hollow.error : hollow.textPrimary,
            backgroundColor: call.isDeafened
                ? hollow.error.withValues(alpha: 0.15)
                : hollow.elevated,
            onTap: call.status == CallStatus.active
                ? () => ref.read(callProvider.notifier).toggleDeafen()
                : null,
          ),
          MobileControlButton(
            icon: LucideIcons.speaker,
            iconSize: iconSize,
            size: buttonSize,
            color: call.isSpeakerOn ? hollow.accent : hollow.textPrimary,
            backgroundColor: call.isSpeakerOn
                ? hollow.accent.withValues(alpha: 0.15)
                : hollow.elevated,
            onTap: canControl
                ? () => ref.read(callProvider.notifier).toggleSpeaker()
                : null,
          ),
          MobileControlButton(
            icon: call.isVideoEnabled
                ? LucideIcons.video
                : LucideIcons.videoOff,
            iconSize: iconSize,
            size: buttonSize,
            color:
                call.isVideoEnabled ? hollow.accent : hollow.textPrimary,
            backgroundColor: call.isVideoEnabled
                ? hollow.accent.withValues(alpha: 0.15)
                : hollow.elevated,
            onTap: call.status == CallStatus.active
                ? () => ref.read(callProvider.notifier).toggleVideo()
                : null,
          ),
          MobileControlButton(
            icon: LucideIcons.phoneOff,
            iconSize: iconSize,
            size: buttonSize,
            color: Colors.white,
            backgroundColor: hollow.error,
            onTap: () => ref.read(callProvider.notifier).endCall(),
          ),
        ],
      ),
    );
  }

}

// ─────────────────────────────────────────────────
// Thin call status strip (shown in chat when call screen is dismissed)
// ─────────────────────────────────────────────────

class MobileCallStatusStrip extends ConsumerWidget {
  final String peerId;
  const MobileCallStatusStrip({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(callProvider);
    final isCallWithThisPeer =
        call.peerId == peerId && call.status != CallStatus.idle;

    // Don't show strip for incoming ringing — the IncomingCallOverlay handles that.
    if (!isCallWithThisPeer) return const SizedBox.shrink();
    if (call.status == CallStatus.ringing &&
        call.direction == CallDirection.incoming) {
      return const SizedBox.shrink();
    }

    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final displayName = displayNameFor(profiles, peerId);

    String label;
    switch (call.status) {
      case CallStatus.ringing:
        label = call.direction == CallDirection.outgoing
            ? 'Calling $displayName...'
            : 'Incoming call...';
      case CallStatus.connecting:
        label = 'Connecting...';
      case CallStatus.active:
        label = 'In call with $displayName';
      case CallStatus.idle:
        label = '';
    }

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          PageRouteBuilder(
            settings: const RouteSettings(name: 'call-screen'),
            pageBuilder: (_, __, ___) =>
                MobileCallScreen(peerId: peerId),
            transitionsBuilder: (_, anim, __, child) {
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 1),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: anim,
                  curve: Curves.easeOut,
                )),
                child: child,
              );
            },
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.success.withValues(alpha: 0.1),
          border: Border(
            bottom:
                BorderSide(color: hollow.success.withValues(alpha: 0.3)),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: hollow.success,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                label,
                style: HollowTypography.caption.copyWith(
                  color: hollow.success,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              'Tap to return',
              style: HollowTypography.caption.copyWith(
                color: hollow.success.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Icon(LucideIcons.chevronUp,
                size: 14, color: hollow.success.withValues(alpha: 0.7)),
          ],
        ),
      ),
    );
  }
}

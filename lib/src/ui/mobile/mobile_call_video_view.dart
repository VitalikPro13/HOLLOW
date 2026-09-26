import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';
import 'package:hollow/src/ui/mobile/mobile_share_fullscreen.dart';
import 'package:hollow/src/ui/mobile/mobile_sheet_drag.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:wakelock_plus/wakelock_plus.dart';


/// The phone's DM call screen, from ringing to hang-up: the other person large
/// with their ring, you in the corner, one row of controls. A camera shows the
/// video with you in a corner; a watched share takes the top of the screen.
class MobileCallScreen extends ConsumerStatefulWidget {
  /// The person called, a MASTER or one of their devices.
  final String peerId;
  const MobileCallScreen({super.key, required this.peerId});

  @override
  ConsumerState<MobileCallScreen> createState() => _MobileCallScreenState();
}

class _MobileCallScreenState extends ConsumerState<MobileCallScreen> {
  Offset _pip = const Offset(HollowSpacing.lg, HollowSpacing.lg);
  bool _wakelockOn = false;

  /// Last logged video-gate tuple, so the log only fires on a change.
  String? _lastVideoGateLog;

  @override
  void dispose() {
    if (_wakelockOn) {
      unawaited(WakelockPlus.disable().catchError((_) {}));
    }
    super.dispose();
  }

  /// Keeps the screen awake while video is on it.
  void _syncWakelock(bool videoShown) {
    if (videoShown == _wakelockOn) return;
    _wakelockOn = videoShown;
    unawaited(WakelockPlus.toggle(enable: videoShown).catchError((_) {}));
  }

  /// Leaves the stack wherever this route sits in it, so a fullscreen share
  /// above is not the one that goes.
  void _close() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final master = ref.watch(deviceLinkProvider).identityOf(widget.peerId);
    final call = ref.watch(callProvider);

    ref.listen<CallStatus>(callProvider.select((c) => c.status), (prev, next) {
      if (next == CallStatus.idle && prev != CallStatus.idle && mounted) {
        _close();
      }
    });

    final source = DmCallStageSource(master);
    final data = source.watchData(context, ref);
    if (data == null) {
      return Scaffold(backgroundColor: hollow.background);
    }
    final me = data.people.first;
    final peer = data.people[1];
    final watched = watchedShareOf(data);
    final video = watched == null && (me.cameraOn || peer.cameraOn);
    _syncWakelock(watched != null || video);
    _logVideoGate(call);

    final Widget body;
    if (watched != null) {
      body = MobileWatchingView(
        data: data,
        share: watched,
        peopleTitle: 'In the call',
        onFullscreen: () =>
            openMobileShareFullscreen(context, source, watched.owner),
      );
    } else if (video) {
      body = _videoView(data, me, peer);
    } else {
      body = _audioView(data, me, peer);
    }

    return MobileSheetDragToMinimize(
      child: Scaffold(
        backgroundColor: hollow.background,
        body: SafeArea(
          child: Column(
            children: [
              MobileCallTopBar(
                title: peer.name,
                subtitle: _subtitle(call),
                onMinimise: () => Navigator.of(context).maybePop(),
                onOpenChat: () => openMobileCallChat(context, peer: master),
              ),
              // A call is when a relay maintenance notice matters most.
              const SystemStatusBanner(),
              Expanded(child: body),
              MobileCallControlRow(controls: _controls(call)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subtitle(CallState call) {
    final startedAt = call.startedAt;
    if (call.status == CallStatus.active && startedAt != null) {
      return CallDurationText(startedAt: startedAt);
    }
    return Text(switch (call.status) {
      CallStatus.ringing => call.direction == CallDirection.outgoing
          ? 'Ringing'
          : 'Incoming call',
      CallStatus.connecting => 'Connecting',
      _ => '',
    });
  }

  /// Audio only: them large, you in the corner, a share offer under the name.
  Widget _audioView(CallStageData data, CallPerson me, CallPerson peer) {
    final hollow = HollowTheme.of(context);
    final offer = _offerOf(data);
    final mine = _mineOf(data);
    return Stack(
      children: [
        Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MobileCallFace(
                  person: peer,
                  size: MobileCallMetrics.peerAvatar,
                  largeRing: true,
                  nameStyle: HollowTypography.heading,
                ),
                _WeakLinkLine(person: peer),
                if (offer != null) ...[
                  const SizedBox(height: HollowSpacing.lg),
                  MobileShareOffer(
                    share: offer,
                    compact: true,
                    onWatch: () => data.onWatch(offer.owner),
                  ),
                ],
                if (mine != null) ...[
                  const SizedBox(height: HollowSpacing.lg),
                  MobileOwnShare(share: mine, onStop: data.onStopSharing),
                ],
              ],
            ),
          ),
        ),
        Positioned(
          top: HollowSpacing.md,
          right: HollowSpacing.lg,
          child: MobileCallFace(
            person: me,
            size: MobileCallMetrics.selfAvatar,
            nameStyle: HollowTypography.caption.copyWith(color: hollow.accentText),
          ),
        ),
      ],
    );
  }

  /// A camera is on: the other person's picture (yours when theirs is off)
  /// fills the screen, yours sits in a corner you can drag.
  Widget _videoView(CallStageData data, CallPerson me, CallPerson peer) {
    final big = peer.cameraOn ? peer : me;
    final pip = peer.cameraOn && me.cameraOn ? me : null;
    final offer = _offerOf(data);
    final mine = _mineOf(data);
    return LayoutBuilder(builder: (context, box) {
      return Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(HollowSpacing.md),
              child: CallPersonTile(person: big, size: CallTileSize.large),
            ),
          ),
          if (pip != null)
            Positioned(
              right: _pip.dx,
              bottom: _pip.dy,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() {
                  _pip = Offset(
                    (_pip.dx - d.delta.dx).clamp(
                        HollowSpacing.md,
                        box.maxWidth -
                            MobileCallMetrics.pipWidth -
                            HollowSpacing.md),
                    (_pip.dy - d.delta.dy).clamp(
                        HollowSpacing.md,
                        box.maxHeight -
                            MobileCallMetrics.pipHeight -
                            HollowSpacing.md),
                  );
                }),
                child: SizedBox(
                  width: MobileCallMetrics.pipWidth,
                  height: MobileCallMetrics.pipHeight,
                  child: CallPersonTile(person: pip, size: CallTileSize.strip),
                ),
              ),
            ),
          // Reachable with a camera on too: the offer used to exist only on
          // the audio screen.
          if (offer != null)
            Positioned(
              top: HollowSpacing.lg,
              left: HollowSpacing.lg,
              right: HollowSpacing.lg,
              child: Center(
                child: MobileShareOffer(
                  share: offer,
                  compact: true,
                  onWatch: () => data.onWatch(offer.owner),
                ),
              ),
            ),
          if (mine != null)
            Positioned(
              left: HollowSpacing.lg,
              right: HollowSpacing.lg,
              bottom: HollowSpacing.lg,
              child: MobileOwnShare(share: mine, onStop: data.onStopSharing),
            ),
        ],
      );
    });
  }

  CallShare? _offerOf(CallStageData data) {
    for (final s in data.shares) {
      if (s.isOffer) return s;
    }
    return null;
  }

  CallShare? _mineOf(CallStageData data) {
    for (final s in data.shares) {
      if (s.isMine) return s;
    }
    return null;
  }

  List<MobileCallControl> _controls(CallState call) {
    final calls = ref.read(callProvider.notifier);
    final active = call.status == CallStatus.active;
    final live = active || call.status == CallStatus.connecting;
    final ringingOut = call.status == CallStatus.ringing &&
        call.direction == CallDirection.outgoing;
    return [
      muteControl(muted: call.isMuted, onTap: live ? calls.toggleMute : null),
      deafenControl(
          deafened: call.isDeafened, onTap: active ? calls.toggleDeafen : null),
      if (isPhoneCallPlatform)
        speakerControl(
          context,
          ref,
          on: call.isSpeakerOn,
          toggle: calls.toggleSpeaker,
          select: calls.selectAudioRoute,
          enabled: live,
        ),
      cameraControl(
        on: call.isVideoEnabled,
        onTap: active ? () => toggleCallCamera(context, dm: true) : null,
      ),
      if (isPhoneCallPlatform || callCanShareScreen)
        shareControl(
          sharing: call.isScreenSharing,
          onTap: active ? () => toggleMobileShare(context, ref, dm: true) : null,
        ),
      if (isPhoneCallPlatform && call.isVideoEnabled)
        flipControl(onTap: active ? calls.switchCamera : null),
      ringingOut
          ? leaveControl(
              word: 'Cancel',
              purpose: 'Cancel',
              onTap: () => leaveDmCall(context, ref))
          : leaveControl(
              word: 'End',
              purpose: 'Leave the call',
              onTap: () => leaveDmCall(context, ref)),
    ];
  }

  /// Device logs are the only way to see why a remote camera is invisible.
  void _logVideoGate(CallState call) {
    final remote = ref.read(callProvider.notifier).voiceService?.remoteRenderer;
    final gate = 'remoteVideoEnabled=${call.remoteVideoEnabled} '
        'remoteRenderer=${remote != null} '
        'srcObject=${remote?.srcObject != null} '
        'local=${call.isVideoEnabled} status=${call.status} '
        'seq=${call.remoteVideoTrackSeq}';
    if (gate == _lastVideoGateLog) return;
    _lastVideoGateLog = gate;
    try {
      network_api
          .logFromDart(message: '[HOLLOW-CALL-UI] video gate: $gate')
          .catchError((Object _) {});
    } catch (_) {
      // No bridge (tests): the gate only matters in a device log.
    }
  }
}

/// "Weak connection" under the other person's name while their link is poor,
/// nothing while it is fine.
class _WeakLinkLine extends ConsumerWidget {
  final CallPerson person;
  const _WeakLinkLine({required this.person});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = person.link;
    final link = source == null ? null : ref.watch(source);
    if (link == null || link.health == LinkHealth.healthy) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.only(top: HollowSpacing.sm),
      child: HollowBadge('Weak connection',
          kind: HollowBadgeKind.warning, icon: LucideIcons.wifiLow),
    );
  }
}

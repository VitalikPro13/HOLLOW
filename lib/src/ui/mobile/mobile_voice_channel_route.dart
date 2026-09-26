import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';
import 'package:hollow/src/ui/mobile/mobile_share_fullscreen.dart';
import 'package:hollow/src/ui/mobile/mobile_sheet_drag.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/ui/shell/voice_quick_controls.dart';
import 'package:wakelock_plus/wakelock_plus.dart';


/// The phone's voice room (and meeting) screen: share offers as cards, then
/// everyone as a two-column grid of tiles; watching a share puts it on top
/// with the room as a row of faces under it.
class MobileVoiceChannelRoute extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;

  /// The join this route was opened for, where the opener started one. A
  /// failed join closes the route; the opener says why.
  final Future<void>? join;

  const MobileVoiceChannelRoute({
    super.key,
    required this.serverId,
    required this.channelId,
    required this.channelName,
    this.join,
  });

  @override
  ConsumerState<MobileVoiceChannelRoute> createState() =>
      _MobileVoiceChannelRouteState();
}

class _MobileVoiceChannelRouteState
    extends ConsumerState<MobileVoiceChannelRoute> {
  bool _wakelockOn = false;

  /// Set once we are in the room; until then the route shows the join.
  bool _joined = false;

  /// Nothing about the join shows for its first second.
  bool _slow = false;
  Timer? _slowTimer;
  Timer? _joinDeadline;

  static const _joinTimeout = Duration(seconds: 20);

  /// How long the join event may trail a join call that returned without one.
  static const _joinGrace = Duration(seconds: 8);

  late final VcCallStageSource _source = VcCallStageSource(
      serverId: widget.serverId, channelId: widget.channelId);

  @override
  void initState() {
    super.initState();
    _joined = _isHere(ref.read(voiceChannelProvider));
    if (_joined) return;
    _slowTimer = Timer(HollowSpinner.revealAfter, () {
      if (mounted) setState(() => _slow = true);
    });
    _armJoinDeadline(_joinTimeout);
    widget.join?.then((_) {
      // A join that returned without entering (no TURN, a call) toasts why.
      if (mounted && !_joined) _armJoinDeadline(_joinGrace);
    }, onError: (Object _) {
      if (mounted && !_joined) _close();
    });
  }

  void _armJoinDeadline(Duration after) {
    _joinDeadline?.cancel();
    _joinDeadline = Timer(after, _giveUpJoin);
  }

  /// Closes a join that never arrived. Offline, the route stays and says so,
  /// and the deadline starts over once the link is back.
  void _giveUpJoin() {
    if (!mounted || _joined) return;
    if (_isOffline(ref.read(overallConnectionProvider))) return;
    HollowToast.show(context, "Couldn't join the room",
        type: HollowToastType.error);
    _close();
  }

  static bool _isOffline(OverallConnection link) =>
      link == OverallConnection.offline ||
      link == OverallConnection.reconnecting ||
      link == OverallConnection.error;

  Future<void> _leaveBeforeJoined() async {
    await leaveVoiceRoom(context, ref);
    if (mounted) _close();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _joinDeadline?.cancel();
    if (_wakelockOn) {
      unawaited(WakelockPlus.disable().catchError((_) {}));
    }
    super.dispose();
  }

  void _syncWakelock(bool videoShown) {
    if (videoShown == _wakelockOn) return;
    _wakelockOn = videoShown;
    unawaited(WakelockPlus.toggle(enable: videoShown).catchError((_) {}));
  }

  bool _isHere(VoiceChannelState s) =>
      s.currentServerId == widget.serverId &&
      s.currentChannelId == widget.channelId;

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

    // Leaving this room, or switching to another, closes it.
    ref.listen<VoiceChannelState>(voiceChannelProvider, (prev, next) {
      if (prev != null && _isHere(prev) && !_isHere(next) && mounted) _close();
    });
    ref.listen<OverallConnection>(overallConnectionProvider, (prev, next) {
      if (!_joined && prev != null && _isOffline(prev) && !_isOffline(next)) {
        _armJoinDeadline(_joinTimeout);
      }
    });

    final data = _source.watchData(context, ref);
    if (data == null) return _joining(hollow);
    if (!_joined) {
      _joined = true;
      _joinDeadline?.cancel();
    }
    final vc = ref.watch(voiceChannelProvider);
    final watched = watchedShareOf(data);
    _syncWakelock(
        watched != null || data.people.any((p) => p.cameraOn));

    final body = watched != null
        ? MobileWatchingView(
            data: data,
            share: watched,
            peopleTitle: 'In the room',
            onFullscreen: () =>
                openMobileShareFullscreen(context, _source, watched.owner),
          )
        : _room(data);

    final conference = _source.isConference;
    final serverName = conference
        ? null
        : ref.watch(
            serverListProvider.select((s) => s[widget.serverId]?.name));
    final joinedAt = vc.joinedAt;

    return MobileSheetDragToMinimize(
      child: Scaffold(
        backgroundColor: hollow.background,
        body: SafeArea(
          child: Column(
            children: [
              MobileCallTopBar(
                title: widget.channelName,
                subtitle: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (serverName != null && serverName.isNotEmpty)
                      Flexible(child: Text('$serverName · ')),
                    if (joinedAt != null) CallDurationText(startedAt: joinedAt),
                  ],
                ),
                onMinimise: () => Navigator.of(context).maybePop(),
                // A meeting's chat lives with the meeting, not in a channel.
                onOpenChat: conference
                    ? null
                    : () => openMobileCallChat(
                          context,
                          serverId: widget.serverId,
                          channelId: widget.channelId,
                          channelName: widget.channelName,
                        ),
              ),
              // Surfaces maintenance and outages while you are in a call.
              const SystemStatusBanner(),
              Expanded(child: body),
              MobileCallControlRow(controls: _controls(vc, conference)),
            ],
          ),
        ),
      ),
    );
  }

  /// Before the join lands: the header, the wait (or why it is stuck), and
  /// Leave, so the screen is never blank or a dead end.
  Widget _joining(HollowTheme hollow) {
    final offline = _isOffline(ref.watch(overallConnectionProvider));
    final conference = _source.isConference;
    final Widget status;
    if (offline) {
      status = const HollowEmptyState(title: "You're offline");
    } else if (!_slow) {
      status = const SizedBox.shrink();
    } else {
      status = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const HollowSpinner.large(),
          const SizedBox(height: HollowSpacing.md),
          Text(
            conference ? 'Joining the meeting' : 'Joining the room',
            style: HollowTypography.bodyTouch
                .copyWith(color: hollow.textSecondary),
          ),
        ],
      );
    }
    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            MobileCallTopBar(
              title: widget.channelName,
              onMinimise: () => Navigator.of(context).maybePop(),
            ),
            Expanded(child: Center(child: status)),
            MobileCallControlRow(controls: [
              leaveControl(
                word: 'Leave',
                purpose: conference ? 'Leave the meeting' : 'Leave the room',
                onTap: _leaveBeforeJoined,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _room(CallStageData data) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(HollowSpacing.lg, HollowSpacing.sm,
          HollowSpacing.lg, HollowSpacing.lg),
      children: [
        for (final s in data.shares)
          if (s.isMine || s.isOffer) ...[
            s.isMine
                ? MobileOwnShare(share: s, onStop: data.onStopSharing)
                : MobileShareOffer(
                    share: s, onWatch: () => data.onWatch(s.owner)),
            const SizedBox(height: HollowSpacing.md),
          ],
        MobileRoomGrid(
          people: data.people,
          onLongPress: (person, globalPosition) {
            final onMenu = person.onMenu;
            if (onMenu == null) return;
            onMenu(context, overlayPositionOf(context, globalPosition));
          },
        ),
      ],
    );
  }

  List<MobileCallControl> _controls(VoiceChannelState vc, bool conference) {
    final notifier = ref.read(voiceChannelProvider.notifier);
    return [
      muteControl(muted: vc.isMuted, onTap: notifier.toggleMute),
      deafenControl(deafened: vc.isDeafened, onTap: notifier.toggleDeafen),
      if (isPhoneCallPlatform)
        speakerControl(
          context,
          ref,
          on: vc.isSpeakerOn,
          toggle: notifier.toggleSpeaker,
          select: notifier.selectAudioRoute,
        ),
      cameraControl(
        on: vc.isCameraOn,
        onTap: () => toggleCallCamera(context, dm: false),
      ),
      if (isPhoneCallPlatform || callCanShareScreen)
        shareControl(
          sharing: vc.isScreenSharing,
          onTap: () => toggleMobileShare(context, ref, dm: false),
        ),
      if (isPhoneCallPlatform && vc.isCameraOn) flipControl(onTap: notifier.switchCamera),
      leaveControl(
        word: 'Leave',
        purpose: conference ? 'Leave the meeting' : 'Leave the room',
        // A meeting is more than its voice leg (B6).
        onTap: () => leaveVoiceRoom(context, ref),
      ),
    ];
  }
}

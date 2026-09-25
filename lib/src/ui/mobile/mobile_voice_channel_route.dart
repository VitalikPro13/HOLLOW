import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
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
  bool _wakelockOn = false;

  late final VcCallStageSource _source = VcCallStageSource(
      serverId: widget.serverId, channelId: widget.channelId);

  @override
  void dispose() {
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

    final data = _source.watchData(context, ref);
    if (data == null) return Scaffold(backgroundColor: hollow.background);
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
        onTap: () => notifier.toggleCamera().catchError((Object _) {}),
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

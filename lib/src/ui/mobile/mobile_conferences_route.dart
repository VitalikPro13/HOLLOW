import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/shell/conference_dashboard.dart'
    show
        conferenceDenyMessage,
        promptConferenceAccessCode,
        showConferenceRoomFormDialog,
        showJoinConferenceDialog;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Mobile conferences: the room list, the joiner's lobby states and the host's
/// waiting room. The call itself reuses [MobileVoiceChannelRoute] with the
/// conference's virtual server id.
class MobileConferencesRoute extends ConsumerStatefulWidget {
  const MobileConferencesRoute({super.key});

  @override
  ConsumerState<MobileConferencesRoute> createState() =>
      _MobileConferencesRouteState();
}

class _MobileConferencesRouteState
    extends ConsumerState<MobileConferencesRoute> {
  bool _callRoutePushed = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(conferenceProvider.notifier).loadRooms());
  }

  void _openCall(ConferenceState conf) {
    if (_callRoutePushed) return;
    _callRoutePushed = true;
    final meetingName = _meetingName(conf);
    Navigator.of(context, rootNavigator: true)
        .push(hollowMobileRoute(
          transition: HollowRouteTransition.slideUp,
          builder: (_) => MobileVoiceChannelRoute(
            serverId: conf.activeServerId,
            channelId: kConferenceChannelId,
            channelName: meetingName,
          ),
        ))
        .then((_) {
      _callRoutePushed = false;
    });
  }

  String _meetingName(ConferenceState conf) {
    if (conf.activeConfId == null) return 'Meeting';
    if (conf.isHost) {
      return conf.roomById(conf.activeConfId!)?.name ?? 'Meeting';
    }
    final hostName = conf.hostName;
    return hostName != null && hostName.isNotEmpty
        ? "$hostName's meeting"
        : 'Meeting';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final conf = ref.watch(conferenceProvider);

    // Pushes the call route once we enter, as host or admitted joiner.
    ref.listen(conferenceProvider.select((s) => s.lobbyStatus), (prev, next) {
      if (prev != ConferenceLobbyStatus.inCall &&
          next == ConferenceLobbyStatus.inCall &&
          mounted) {
        _openCall(ref.read(conferenceProvider));
      }
    });

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(hollow),
            Expanded(child: _buildBody(hollow, conf)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          HollowPressable(
            semanticLabel: 'Back',
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.arrowLeft,
                size: 22, color: hollow.textPrimary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              'Conferences',
              style: HollowTypography.heading
                  .copyWith(color: hollow.textPrimary),
            ),
          ),
          HollowTooltip(
            message: 'Join a meeting',
            child: HollowPressable(
              semanticLabel: 'Join a meeting',
              onTap: () => showJoinConferenceDialog(context),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child:
                  Icon(LucideIcons.logIn, size: 22, color: hollow.accent),
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowPressable(
            semanticLabel: 'Create room',
            onTap: () => showConferenceRoomFormDialog(context),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.plus, size: 22, color: hollow.accent),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(HollowTheme hollow, ConferenceState conf) {
    if (conf.meetingActive) {
      switch (conf.lobbyStatus) {
        case ConferenceLobbyStatus.waiting:
        case ConferenceLobbyStatus.admitted:
          return _buildLobby(hollow, conf);
        case ConferenceLobbyStatus.denied:
          return _buildDenied(hollow, conf);
        case ConferenceLobbyStatus.inCall:
          return _buildInCall(hollow, conf);
        case ConferenceLobbyStatus.none:
          break;
      }
    }
    return _buildRoomList(hollow, conf);
  }

  Widget _buildRoomList(HollowTheme hollow, ConferenceState conf) {
    if (conf.rooms.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.video,
                  size: 48,
                  color: hollow.textSecondary.withValues(alpha: 0.4)),
              const SizedBox(height: HollowSpacing.lg),
              Text('No conference rooms yet',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textSecondary)),
              const SizedBox(height: HollowSpacing.sm),
              Text(
                'Create a room and share its link to meet anyone.',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.md),
      children: [
        for (final room in conf.rooms) ...[
          _buildRoomCard(hollow, room),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ],
    );
  }

  Widget _buildRoomCard(HollowTheme hollow, ConferenceRoom room) {
    final badges = <String>[
      if (room.waitingRoom) 'Waiting room',
      if (room.hasAccessCode) 'Access code',
    ];
    return Container(
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(LucideIcons.video, size: 18, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  room.name,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HollowPressable(
                semanticLabel: 'Copy invite link for ${room.name}',
                onTap: () {
                  Clipboard.setData(ClipboardData(text: room.inviteLink));
                  HollowToast.show(context, 'Invite link copied',
                      type: HollowToastType.success);
                },
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.link,
                    size: 18, color: hollow.textSecondary),
              ),
              HollowPressable(
                semanticLabel: 'Edit room ${room.name}',
                onTap: () =>
                    showConferenceRoomFormDialog(context, room: room),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.pencil,
                    size: 18, color: hollow.textSecondary),
              ),
              HollowPressable(
                semanticLabel: 'Delete room ${room.name}',
                onTap: () => _confirmDelete(room),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.trash2,
                    size: 18, color: hollow.textSecondary),
              ),
            ],
          ),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.xs),
            Text(
              badges.join('  ·  '),
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary),
            ),
          ],
          const SizedBox(height: HollowSpacing.sm),
          HollowButton.filled(
            compact: true,
            expand: true,
            icon: const Icon(LucideIcons.video, size: 14),
            onPressed: () =>
                ref.read(conferenceProvider.notifier).startMeeting(room),
            child: const Text('Start meeting'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(ConferenceRoom room) async {
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) {
        final h = HollowTheme.of(ctx);
        return HollowDialog(
          title: 'Delete Room?',
          content: Text(
            'Delete "${room.name}"? Its invite link stops working forever.',
            style: HollowTypography.body.copyWith(color: h.textSecondary),
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            HollowButton.danger(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await ref.read(conferenceProvider.notifier).deleteRoom(room.confId);
    }
  }

  Widget _buildLobby(HollowTheme hollow, ConferenceState conf) {
    final hostName = conf.hostName;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (conf.hostPeerId != null)
              HollowAvatar(
                // LobbyInfo carries the host's DEVICE id, the WS sender, while
                // profiles and avatars are MASTER-keyed.
                peerId: ref
                    .watch(deviceLinkProvider)
                    .identityOf(conf.hostPeerId!),
                size: 64,
                semanticLabel: hostName ?? 'Meeting host',
              )
            else
              Icon(LucideIcons.video, size: 48, color: hollow.accent),
            const SizedBox(height: HollowSpacing.lg),
            Text(
              hostName != null && hostName.isNotEmpty
                  ? "You're in the waiting room for $hostName's meeting"
                  : 'Waiting for the host to start the meeting',
              style: HollowTypography.heading
                  .copyWith(color: hollow.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              // LobbyInfo is the host's reply to our knock, so until it arrives
              // the meeting has not started.
              hostName != null && hostName.isNotEmpty
                  ? 'Waiting for the host to let you in…'
                  : "You'll join automatically once it begins.",
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.lg),
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: hollow.accent,
              ),
            ),
            const SizedBox(height: HollowSpacing.xl),
            HollowButton.ghost(
              onPressed: () =>
                  ref.read(conferenceProvider.notifier).leaveMeeting(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDenied(HollowTheme hollow, ConferenceState conf) {
    final wrongCode = conf.denyReason == 'wrong_code';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.doorClosed,
                size: 48,
                color: hollow.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: HollowSpacing.lg),
            Text(
              conferenceDenyMessage(conf.denyReason),
              style: HollowTypography.heading
                  .copyWith(color: hollow.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.xl),
            if (wrongCode) ...[
              HollowButton.filled(
                onPressed: () => _retryWithCode(conf),
                child: const Text('Enter access code'),
              ),
              const SizedBox(height: HollowSpacing.sm),
            ],
            HollowButton.ghost(
              onPressed: () =>
                  ref.read(conferenceProvider.notifier).leaveMeeting(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryWithCode(ConferenceState conf) async {
    final confId = conf.activeConfId;
    if (confId == null) return;
    final code = await promptConferenceAccessCode(context);
    if (code == null || code.isEmpty) return;
    await ref
        .read(conferenceProvider.notifier)
        .requestJoin(confId, accessCode: code);
  }

  Widget _buildInCall(HollowTheme hollow, ConferenceState conf) {
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.md),
      children: [
        Container(
          padding: const EdgeInsets.all(HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.video, size: 18, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      _meetingName(conf),
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HollowSpacing.sm),
              HollowButton.filled(
                compact: true,
                expand: true,
                onPressed: () => _openCall(conf),
                child: const Text('Open call'),
              ),
              const SizedBox(height: HollowSpacing.sm),
              if (conf.isHost)
                HollowButton.danger(
                  compact: true,
                  expand: true,
                  onPressed: () =>
                      ref.read(conferenceProvider.notifier).endMeeting(),
                  child: const Text('End meeting'),
                )
              else
                HollowButton.ghost(
                  compact: true,
                  expand: true,
                  onPressed: () =>
                      ref.read(conferenceProvider.notifier).leaveMeeting(),
                  child: const Text('Leave meeting'),
                ),
            ],
          ),
        ),
        if (conf.isHost && conf.waiting.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          Text(
            'Waiting Room (${conf.waiting.length})',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          for (final entry in conf.waiting) ...[
            _buildWaitingRow(hollow, entry),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ],
      ],
    );
  }

  Widget _buildWaitingRow(HollowTheme hollow, WaitingEntry entry) {
    final shortId = entry.peerId.length > 12
        ? '${entry.peerId.substring(0, 12)}…'
        : entry.peerId;
    return Container(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          HollowAvatar(
            peerId: entry.peerId,
            size: 32,
            semanticLabel: entry.displayName,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.displayName.isNotEmpty
                            ? entry.displayName
                            : shortId,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (entry.isFriend) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      Text(
                        'Friend',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.success,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  shortId,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textTertiary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          HollowButton.ghost(
            compact: true,
            onPressed: () =>
                ref.read(conferenceProvider.notifier).deny(entry.peerId),
            child: const Text('Decline'),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowButton.filled(
            compact: true,
            onPressed: () =>
                ref.read(conferenceProvider.notifier).admit(entry.peerId),
            child: const Text('Admit'),
          ),
        ],
      ),
    );
  }
}

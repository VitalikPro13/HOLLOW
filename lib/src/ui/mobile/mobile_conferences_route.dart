import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/ui/shell/conference_actions.dart';
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
        vertical: HollowSpacing.xs,
      ),
      child: Row(
        children: [
          HollowIconButton(
            icon: LucideIcons.arrowLeft,
            label: 'Back',
            size: 44,
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: Text(
              'Conferences',
              style:
                  HollowTypography.heading.copyWith(color: hollow.textPrimary),
            ),
          ),
          HollowIconButton(
            icon: LucideIcons.logIn,
            label: 'Join a meeting',
            size: 44,
            onPressed: () => showJoinConferenceDialog(context),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowIconButton(
            icon: LucideIcons.plus,
            label: 'Create a room',
            size: 44,
            onPressed: () => showConferenceRoomFormDialog(context),
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
      return const HollowEmptyState(
        glyph: LucideIcons.video,
        title: 'No conference rooms yet',
        description: 'Create a room and share its link to meet anyone.',
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      children: [
        for (final room in conf.rooms)
          _MobileRoomRow(key: ValueKey(room.confId), room: room),
      ],
    );
  }

  Widget _buildLobby(HollowTheme hollow, ConferenceState conf) {
    final hostName = conf.hostName;
    final hostKnown = hostName != null && hostName.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (conf.hostPeerId != null) ...[
              HollowAvatar(
                // LobbyInfo carries the host's DEVICE id, the WS sender, while
                // profiles and avatars are MASTER-keyed.
                peerId: ref
                    .watch(deviceLinkProvider)
                    .identityOf(conf.hostPeerId!),
                size: 64,
                semanticLabel: hostName ?? 'Meeting host',
              ),
              const SizedBox(height: HollowSpacing.lg),
            ],
            Text(
              hostKnown
                  ? "You're in the waiting room for $hostName's meeting"
                  : 'Waiting for the host to start the meeting',
              style: HollowTypography.subheading
                  .copyWith(color: hollow.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              // LobbyInfo is the host's reply to our knock, so until it arrives
              // the meeting has not started.
              hostKnown
                  ? 'The host will let you in.'
                  : "You'll join automatically once it begins.",
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.lg),
            const HollowSpinner.medium(),
            const SizedBox(height: HollowSpacing.lg),
            HollowButton.ghost(
              touch: true,
              onPressed: () => leaveConferenceMeeting(context, ref),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDenied(HollowTheme hollow, ConferenceState conf) {
    final wrongCode = conf.denyReason == 'wrong_code';
    return HollowEmptyState(
      glyph: LucideIcons.doorClosed,
      title: conferenceDenyMessage(conf.denyReason),
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (wrongCode) ...[
            HollowButton.filled(
              touch: true,
              onPressed: () => _retryWithCode(conf),
              child: const Text('Enter access code'),
            ),
            const SizedBox(height: HollowSpacing.sm),
          ],
          HollowButton.ghost(
            touch: true,
            onPressed: () => leaveConferenceMeeting(context, ref),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Future<void> _retryWithCode(ConferenceState conf) async {
    final confId = conf.activeConfId;
    if (confId == null) return;
    final notifier = ref.read(conferenceProvider.notifier);
    final code = await promptConferenceAccessCode(context);
    if (code == null || code.isEmpty) return;
    await notifier.requestJoin(confId, accessCode: code);
  }

  Widget _buildInCall(HollowTheme hollow, ConferenceState conf) {
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        Text(
          _meetingName(conf),
          style: HollowTypography.subheading.copyWith(color: hollow.textPrimary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: HollowSpacing.md),
        HollowButton.filled(
          touch: true,
          expand: true,
          onPressed: () => _openCall(conf),
          child: const Text('Open call'),
        ),
        const SizedBox(height: HollowSpacing.sm),
        if (conf.isHost)
          HollowButton.outline(
            touch: true,
            expand: true,
            danger: true,
            onPressed: () => endConferenceMeeting(context, ref),
            child: const Text('End meeting'),
          )
        else
          HollowButton.ghost(
            touch: true,
            expand: true,
            onPressed: () => leaveConferenceMeeting(context, ref),
            child: const Text('Leave meeting'),
          ),
        if (conf.isHost && conf.waiting.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.xl),
          HollowSectionHeader('Waiting room',
              dense: true, count: '${conf.waiting.length}'),
          for (final entry in conf.waiting)
            _MobileWaitingRow(key: ValueKey(entry.peerId), entry: entry),
        ],
      ],
    );
  }
}

/// One room at touch size: its name, what it asks of a joiner, Start meeting,
/// and More (also on a long press) with the rest.
class _MobileRoomRow extends ConsumerWidget {
  final ConferenceRoom room;
  const _MobileRoomRow({super.key, required this.room});

  void _openMenu(BuildContext context, WidgetRef ref, Offset anchor) {
    showConferenceRoomMenu(
      context,
      ref,
      room,
      anchor: anchor,
      alignEnd: true,
      withCopyLink: true,
      onEdit: () => showConferenceRoomFormDialog(context, room: room),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (d) => _openMenu(
          context, ref, overlayPositionOf(context, d.globalPosition)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    room.name,
                    style: HollowTypography.bodyTouch.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    conferenceRoomFacts(room),
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.outline(
              compact: true,
              touch: true,
              onPressed: () =>
                  ref.read(conferenceProvider.notifier).startMeeting(room),
              child: const Text('Start meeting'),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Builder(
              builder: (buttonContext) => HollowIconButton(
                icon: LucideIcons.moreHorizontal,
                label: 'More actions for ${room.name}',
                tooltip: 'More',
                size: 44,
                onPressed: () => _openMenu(
                  context,
                  ref,
                  overlayAnchorOf(buttonContext,
                      localOffset: Offset(buttonContext.size?.width ?? 0,
                          buttonContext.size?.height ?? 0)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileWaitingRow extends ConsumerWidget {
  final WaitingEntry entry;
  const _MobileWaitingRow({super.key, required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final notifier = ref.read(conferenceProvider.notifier);
    final name =
        entry.displayName.isNotEmpty ? entry.displayName : 'Someone';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      child: Row(
        children: [
          HollowAvatar(
            // The knock arrives from a DEVICE id; profiles are MASTER-keyed.
            peerId: ref.watch(deviceLinkProvider).identityOf(entry.peerId),
            size: 36,
            semanticLabel: name,
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    style: HollowTypography.bodyTouch.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (entry.isFriend) ...[
                  const SizedBox(width: HollowSpacing.xs),
                  const HollowBadge('Friend', kind: HollowBadgeKind.success),
                ],
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            compact: true,
            touch: true,
            onPressed: () => notifier.deny(entry.peerId),
            child: const Text('Decline'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.outline(
            compact: true,
            touch: true,
            onPressed: () => notifier.admit(entry.peerId),
            child: const Text('Admit'),
          ),
        ],
      ),
    );
  }
}

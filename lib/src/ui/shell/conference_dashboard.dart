import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_side_panel.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/call/speaking_ring.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart'
    show ChatHeaderBar;
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart' show SettingsSwitchRow;
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shell/conference_actions.dart';
import 'package:hollow/src/ui/shell/place_header.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Human-readable joiner-side denial message.
String conferenceDenyMessage(String? reason) {
  switch (reason) {
    case 'wrong_code':
      return 'Wrong access code';
    case 'declined':
      return 'The host declined your request.';
    case 'request_failed':
      return 'Could not reach the meeting. Try again.';
    default:
      return 'You could not join this meeting.';
  }
}

/// Display name for a possibly device-level peer id, collapsed to master first.
String conferenceDisplayName(WidgetRef ref, String peerId) {
  final master = ref.watch(deviceLinkProvider).identityOf(peerId);
  return displayNameFor(ref.watch(profileProvider), master);
}

/// Prompt for a conference access code. Returns null on cancel.
Future<String?> promptConferenceAccessCode(BuildContext context) {
  return showHollowDialog<String>(
    context: context,
    builder: (_) => const _AccessCodeDialog(),
  );
}

/// Create/edit conference room dialog. Pass [room] to edit.
Future<void> showConferenceRoomFormDialog(BuildContext context,
    {ConferenceRoom? room}) {
  return showHollowDialog<void>(
    context: context,
    builder: (_) => _RoomFormDialog(room: room),
  );
}

/// Desktop centre-tab surface for Conferences: room manager, joiner lobby and
/// the in-meeting call surface.
class ConferenceDashboard extends ConsumerStatefulWidget {
  const ConferenceDashboard({super.key});

  @override
  ConsumerState<ConferenceDashboard> createState() =>
      _ConferenceDashboardState();
}

class _ConferenceDashboardState extends ConsumerState<ConferenceDashboard> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(conferenceProvider.notifier).loadRooms());
  }

  @override
  Widget build(BuildContext context) {
    final conf = ref.watch(conferenceProvider);

    // Switching views is instant; the key resets each view's state.
    return KeyedSubtree(
      key: ValueKey(_viewKey(conf)),
      child: _buildView(context, conf),
    );
  }

  String _viewKey(ConferenceState conf) {
    if (conf.meetingActive) {
      switch (conf.lobbyStatus) {
        case ConferenceLobbyStatus.waiting:
        case ConferenceLobbyStatus.admitted:
          return 'lobby-${conf.activeConfId}';
        case ConferenceLobbyStatus.denied:
          return 'denied-${conf.activeConfId}';
        case ConferenceLobbyStatus.inCall:
          return 'call-${conf.activeConfId}';
        case ConferenceLobbyStatus.none:
          break;
      }
    }
    return 'rooms';
  }

  Widget _buildView(BuildContext context, ConferenceState conf) {
    final hollow = HollowTheme.of(context);

    if (conf.meetingActive) {
      switch (conf.lobbyStatus) {
        case ConferenceLobbyStatus.waiting:
        case ConferenceLobbyStatus.admitted:
          return _LobbyView(conf: conf);
        case ConferenceLobbyStatus.denied:
          return _DeniedView(conf: conf);
        case ConferenceLobbyStatus.inCall:
          return _CallView(conf: conf);
        case ConferenceLobbyStatus.none:
          break; // Inconsistent transient: fall through to the room list.
      }
    }

    return ColoredBox(
      color: hollow.background,
      child: Column(
        children: [
          PlaceHeader(
            title: 'Conferences',
            actions: [
              HollowButton.ghost(
                compact: true,
                icon: const Icon(LucideIcons.logIn, size: 14),
                onPressed: () => showJoinConferenceDialog(context),
                child: const Text('Join a meeting'),
              ),
              HollowButton.filled(
                compact: true,
                icon: const Icon(LucideIcons.plus, size: 14),
                onPressed: () => showConferenceRoomFormDialog(context),
                child: const Text('Create a room'),
              ),
            ],
          ),
          Expanded(
            child: conf.rooms.isEmpty
                ? const HollowEmptyState(
                    glyph: LucideIcons.video,
                    title: 'No conference rooms yet',
                    description: 'Create a room and share its link to meet '
                        'anyone. No server or friendship needed.',
                  )
                : ListView(
                    // Plus the row's own padding, the names sit on the
                    // title's edge.
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    children: [
                      for (final room in conf.rooms)
                        _RoomRow(key: ValueKey(room.confId), room: room),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// One room: its name, what it asks of a joiner, and its actions. Edit and
/// Delete sit in More (and a right click), out of reach at rest.
class _RoomRow extends ConsumerWidget {
  final ConferenceRoom room;
  const _RoomRow({super.key, required this.room});

  void _openMenu(BuildContext context, WidgetRef ref, Offset anchor,
      {bool alignEnd = false}) {
    showConferenceRoomMenu(
      context,
      ref,
      room,
      anchor: anchor,
      alignEnd: alignEnd,
      onEdit: () => showConferenceRoomFormDialog(context, room: room),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ContextMenuTarget(
      semanticLabel: 'Room actions',
      onOpen: (anchor) => _openMenu(context, ref, anchor),
      child: HollowListRow(
        title: room.name,
        subtitle: conferenceRoomFacts(room),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowIconButton(
              icon: LucideIcons.link,
              label: 'Copy invite link for ${room.name}',
              tooltip: 'Copy invite link',
              onPressed: () => copyConferenceInviteLink(context, ref, room),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.outline(
              compact: true,
              icon: const Icon(LucideIcons.video, size: 14),
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
                onPressed: () => _openMenu(
                  context,
                  ref,
                  overlayAnchorOf(buttonContext,
                      localOffset: Offset(
                          (buttonContext.size?.width ?? 0),
                          buttonContext.size?.height ?? 0)),
                  alignEnd: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoomFormDialog extends ConsumerStatefulWidget {
  final ConferenceRoom? room;
  const _RoomFormDialog({this.room});

  @override
  ConsumerState<_RoomFormDialog> createState() => _RoomFormDialogState();
}

class _RoomFormDialogState extends ConsumerState<_RoomFormDialog>
    with HollowDialogAction {
  late final TextEditingController _nameController;
  late final TextEditingController _codeController;
  late bool _waitingRoom;
  bool _removeCode = false;

  bool get _isEdit => widget.room != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.room?.name ?? '');
    _codeController = TextEditingController();
    _waitingRoom = widget.room?.waitingRoom ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  /// Stays open until the room is saved, so a failure keeps what was typed.
  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final notifier = ref.read(conferenceProvider.notifier);
    final code = _codeController.text.trim();
    final room = widget.room;
    final saved = await runDialogAction(
      () => room != null
          ? notifier.updateRoom(
              confId: room.confId,
              name: name,
              waitingRoom: _waitingRoom,
              // COALESCE convention: null keeps the existing code, '' clears.
              accessCode: _removeCode ? '' : (code.isEmpty ? null : code),
              broadcastMode: room.broadcastMode,
            )
          : notifier.createRoom(
              name: name,
              waitingRoom: _waitingRoom,
              accessCode: code,
            ),
      fallback: room != null
          ? "Couldn't save the room. Try again."
          : "Couldn't create the room. Try again.",
    );
    if (saved && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hasCode = widget.room?.hasAccessCode ?? false;

    return HollowDialog(
      title: _isEdit ? 'Edit room' : 'Create room',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SettingsFieldLabel(label: 'Room name'),
          const SizedBox(height: HollowSpacing.sm),
          HollowTextField(
            controller: _nameController,
            hintText: 'e.g. Weekly sync',
            autofocus: true,
            maxLength: 64,
            showCounter: false,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: HollowSpacing.md),
          SettingsSwitchRow(
            title: 'Waiting room',
            subtitle: 'Approve each joiner before they enter',
            value: _waitingRoom,
            onChanged: (v) => setState(() => _waitingRoom = v),
          ),
          const SizedBox(height: HollowSpacing.md),
          if (_isEdit && hasCode)
            SettingsSwitchRow(
              title: 'Remove access code',
              subtitle: 'Anyone with the link can ask to join',
              value: _removeCode,
              onChanged: (v) => setState(() => _removeCode = v),
            ),
          // Removing the code and typing a new one would contradict each
          // other, so the field steps aside while the code is being removed.
          if (!_removeCode) ...[
            if (_isEdit && hasCode) const SizedBox(height: HollowSpacing.md),
            SettingsFieldLabel(
                label: _isEdit && hasCode
                    ? 'New access code (optional)'
                    : 'Access code (optional)'),
            const SizedBox(height: HollowSpacing.sm),
            HollowTextField(
              controller: _codeController,
              hintText: _isEdit && hasCode
                  ? 'Leave empty to keep the current code'
                  : 'Leave empty for none',
              maxLength: 64,
              showCounter: false,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          loading: actionRunning,
          onPressed: _nameController.text.trim().isEmpty ? null : _submit,
          child: Text(_isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}

/// Paste-a-link join dialog: accepts a full invite link (either the
/// hollow:// or web form) or a bare meeting id. Shared with mobile.
Future<void> showJoinConferenceDialog(BuildContext context) {
  return showHollowDialog<void>(
    context: context,
    builder: (_) => const _JoinConferenceDialog(),
  );
}

class _JoinConferenceDialog extends ConsumerStatefulWidget {
  const _JoinConferenceDialog();

  @override
  ConsumerState<_JoinConferenceDialog> createState() =>
      _JoinConferenceDialogState();
}

class _JoinConferenceDialogState extends ConsumerState<_JoinConferenceDialog>
    with HollowDialogAction {
  static final _idRe = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final text = _controller.text.trim();
    if (text.isEmpty || actionRunning) return;
    String? confId;
    final link = classifyHollowLink(text);
    if (link != null) {
      if (link.type == HollowLinkType.conference) {
        confId = link.id;
      } else {
        setState(() => _error = "That's a ${switch (link.type) {
              HollowLinkType.serverInvite => 'server invite',
              HollowLinkType.roomInvite => 'room invite',
              HollowLinkType.share => 'share link',
              HollowLinkType.recovery => 'recovery link',
              HollowLinkType.conference => 'conference link',
              HollowLinkType.redeem => 'support code',
            }}, not a meeting link");
        return;
      }
    } else if (_idRe.hasMatch(text)) {
      confId = text; // bare meeting id
    }
    if (confId == null) {
      setState(() => _error = 'Paste a meeting link or its id');
      return;
    }
    final id = confId;
    // The relay check may ask to switch relays, so it runs before the
    // dialog shows its own busy state.
    if (!await ensureRelayForInviteId(context, ref,
        type: HollowLinkType.conference, id: id, relay: link?.relay)) {
      return;
    }
    if (!mounted) return;
    final notifier = ref.read(conferenceProvider.notifier);
    if (await runDialogAction(() => notifier.requestJoin(id),
            fallback: "Couldn't reach the meeting. Try again.") &&
        mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Join a meeting',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowDialogText('Paste a meeting invite link or its id.'),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _controller,
            hintText: 'Paste the meeting link',
            autofocus: true,
            errorText: _error,
            onSubmitted: (_) => _join(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _join,
          loading: actionRunning,
          child: const Text('Join'),
        ),
      ],
    );
  }
}

class _AccessCodeDialog extends StatefulWidget {
  const _AccessCodeDialog();

  @override
  State<_AccessCodeDialog> createState() => _AccessCodeDialogState();
}

class _AccessCodeDialogState extends State<_AccessCodeDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    Navigator.of(context).pop(code);
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Access code',
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowDialogText('This meeting requires an access code.'),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _controller,
            hintText: 'Access code',
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _submit,
          child: const Text('Join'),
        ),
      ],
    );
  }
}

class _LobbyView extends ConsumerWidget {
  final ConferenceState conf;
  const _LobbyView({required this.conf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final hostName = conf.hostName;
    final hostKnown = hostName != null && hostName.isNotEmpty;

    return ColoredBox(
      color: hollow.background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (conf.hostPeerId != null) ...[
                HollowAvatar(
                  // LobbyInfo carries the host's DEVICE id, and profiles are
                  // keyed by their MASTER.
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
                // LobbyInfo is the host's reply to our knock, so until it
                // arrives the meeting has not started.
                hostKnown
                    ? 'The host will let you in.'
                    : "You'll join automatically once it begins.",
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: HollowSpacing.lg),
              const HollowSpinner.medium(),
              const SizedBox(height: HollowSpacing.lg),
              HollowButton.ghost(
                onPressed: () => leaveConferenceMeeting(context, ref),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeniedView extends ConsumerWidget {
  final ConferenceState conf;
  const _DeniedView({required this.conf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final wrongCode = conf.denyReason == 'wrong_code';

    return ColoredBox(
      color: hollow.background,
      child: HollowEmptyState(
        glyph: LucideIcons.doorClosed,
        title: conferenceDenyMessage(conf.denyReason),
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowButton.ghost(
              onPressed: () => leaveConferenceMeeting(context, ref),
              child: const Text('Back'),
            ),
            if (wrongCode) ...[
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                onPressed: () => _retryWithCode(context, ref),
                child: const Text('Enter access code'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _retryWithCode(BuildContext context, WidgetRef ref) async {
    final confId = conf.activeConfId;
    if (confId == null) return;
    final notifier = ref.read(conferenceProvider.notifier);
    final code = await promptConferenceAccessCode(context);
    if (code == null || code.isEmpty) return;
    await notifier.requestJoin(confId, accessCode: code);
  }
}

/// What the meeting's one side panel shows.
enum _MeetingPanel { chat, people }

/// Everyone in the meeting, us first. The participant set is DEVICE-keyed,
/// so seeding it with the MASTER id would list us twice.
({String selfId, List<String> all}) _meetingParticipants(
    WidgetRef ref, ConferenceState conf, VoiceChannelState vcState) {
  final localPeerId = ref.watch(identityProvider).peerId ?? '';
  final selfId = vcState.selfParticipantId(
        conf.activeServerId,
        kConferenceChannelId,
        master: localPeerId,
        device: ref.watch(localDevicePeerIdProvider).valueOrNull,
      ) ??
      localPeerId;
  final all = <String>{
    selfId,
    ...vcState.getParticipants(conf.activeServerId, kConferenceChannelId),
  }.where((p) => p.isNotEmpty).toList();
  return (selfId: selfId, all: all);
}

String _meetingName(ConferenceState conf) {
  if (conf.isHost) return conf.roomById(conf.activeConfId!)?.name ?? 'Meeting';
  final hostName = conf.hostName;
  return hostName != null && hostName.isNotEmpty
      ? "$hostName's meeting"
      : 'Meeting';
}

/// The meeting: the stage, and ONE side panel on the right holding the chat
/// or the people in it.
class _CallView extends ConsumerStatefulWidget {
  final ConferenceState conf;
  const _CallView({required this.conf});

  @override
  ConsumerState<_CallView> createState() => _CallViewState();
}

class _CallViewState extends ConsumerState<_CallView> {
  _MeetingPanel? _panel = _MeetingPanel.chat;

  // Panels show and hide instantly: a width animation re-lays the stage.
  void _toggle(_MeetingPanel panel) {
    setState(() => _panel = _panel == panel ? null : panel);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final conf = widget.conf;
    final meetingName = _meetingName(conf);
    final waiting = conf.isHost ? conf.waiting.length : 0;

    // A knock deserves attention, so the host sees who is waiting.
    ref.listen(
        conferenceProvider.select((s) => s.isHost ? s.waiting.length : 0),
        (prev, next) {
      if (prev != null && next > prev) {
        setState(() => _panel = _MeetingPanel.people);
      }
    });

    return ColoredBox(
      color: hollow.background,
      child: Column(
        children: [
          PlaceHeader(
            title: meetingName,
            actions: [
              if (conf.isHost)
                HollowButton.ghost(
                  compact: true,
                  icon: const Icon(LucideIcons.link, size: 14),
                  onPressed: () {
                    final link = webConferenceInviteLink(conf.activeConfId!,
                        relay: ref.read(relayDomainProvider));
                    Clipboard.setData(ClipboardData(text: link));
                    HollowToast.show(context, 'Invite link copied',
                        type: HollowToastType.success);
                  },
                  child: const Text('Copy link'),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HollowIconButton(
                    icon: LucideIcons.messageSquare,
                    label: 'Chat',
                    selected: _panel == _MeetingPanel.chat,
                    onPressed: () => _toggle(_MeetingPanel.chat),
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  HollowIconButton(
                    icon: LucideIcons.users,
                    label: 'People',
                    count: waiting > 0 ? '$waiting' : null,
                    selected: _panel == _MeetingPanel.people,
                    onPressed: () => _toggle(_MeetingPanel.people),
                  ),
                ],
              ),
              // Leaving is the bar's; ending it for everyone stays up here.
              if (conf.isHost)
                HollowButton.outline(
                  compact: true,
                  danger: true,
                  onPressed: () => endConferenceMeeting(context, ref),
                  child: const Text('End meeting'),
                ),
            ],
          ),
          Expanded(
            child: CallStageWithPanel(
              stage:
                  _ConferenceCallArea(conf: conf, meetingName: meetingName),
              panel: _panel == null
                  ? null
                  : _MeetingSidePanel(conf: conf, panel: _panel!),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the meeting's side panel shows; [CallStageWithPanel] frames and sizes
/// it.
class _MeetingSidePanel extends StatelessWidget {
  final ConferenceState conf;
  final _MeetingPanel panel;

  const _MeetingSidePanel({required this.conf, required this.panel});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // The header's Chat and People buttons switch it; its own header names
    // what it shows, so nothing here repeats them.
    return panel == _MeetingPanel.chat
          ? ChannelChatPane(
              // The ONE conference chat, RAM-only under a 'conf:' key.
              serverId: conf.activeServerId,
              channelId: kConferenceChannelId,
              // Also the composer's hint, which a long room name would wrap.
              channelName: 'the meeting',
              headerTitle: 'Chat',
              isVoice: true,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChatHeaderBar(
                  leading: Icon(LucideIcons.users,
                      size: 20, color: hollow.textTertiary),
                  title: 'People',
                ),
                Expanded(child: _PeoplePanel(conf: conf)),
              ],
            );
  }
}

/// Search, the host's waiting room, and everyone in the meeting.
class _PeoplePanel extends ConsumerStatefulWidget {
  final ConferenceState conf;
  const _PeoplePanel({required this.conf});

  @override
  ConsumerState<_PeoplePanel> createState() => _PeoplePanelState();
}

class _PeoplePanelState extends ConsumerState<_PeoplePanel> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(String name) =>
      _query.isEmpty || name.toLowerCase().contains(_query.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final conf = ref.watch(conferenceProvider);
    final vcState = ref.watch(voiceChannelProvider);
    final links = ref.watch(deviceLinkProvider);
    final (:selfId, :all) = _meetingParticipants(ref, conf, vcState);

    final waiting = conf.isHost
        ? conf.waiting.where((w) => _matches(w.displayName)).toList()
        : const <WaitingEntry>[];
    final shown = all
        .where((p) =>
            _matches(p == selfId ? 'You' : conferenceDisplayName(ref, p)))
        .toList();

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.md),
      children: [
        HollowTextField(
          controller: _searchController,
          hintText: 'Search people',
          isDense: true,
          prefixIcon: Icon(LucideIcons.search,
              size: 14, color: hollow.textSecondary),
          onChanged: (v) => setState(() => _query = v.trim()),
        ),
        const SizedBox(height: HollowSpacing.md),
        if (waiting.isNotEmpty) ...[
          HollowSectionHeader('Waiting room',
              dense: true, count: '${waiting.length}'),
          for (final entry in waiting)
            _WaitingRow(key: ValueKey(entry.peerId), entry: entry, links: links),
          const SizedBox(height: HollowSpacing.lg),
        ],
        HollowSectionHeader('In the meeting',
            dense: true, count: '${shown.length}'),
        for (final peerId in shown)
          _ParticipantRow(
            key: ValueKey(peerId),
            peerId: peerId,
            isSelf: peerId == selfId,
            canKick: conf.isHost && peerId != selfId,
          ),
      ],
    );
  }
}

class _WaitingRow extends ConsumerWidget {
  final WaitingEntry entry;
  final DeviceLinkState links;
  const _WaitingRow({super.key, required this.entry, required this.links});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final notifier = ref.read(conferenceProvider.notifier);
    final name =
        entry.displayName.isNotEmpty ? entry.displayName : 'Someone';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        children: [
          HollowAvatar(
            // The knock arrives from a DEVICE id, while profiles are keyed by
            // the person's master.
            peerId: links.identityOf(entry.peerId),
            size: 28,
            semanticLabel: name,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    style: HollowTypography.label
                        .copyWith(color: hollow.textPrimary),
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
            onPressed: () => notifier.deny(entry.peerId),
            child: const Text('Decline'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.outline(
            compact: true,
            onPressed: () => notifier.admit(entry.peerId),
            child: const Text('Admit'),
          ),
        ],
      ),
    );
  }
}

class _ParticipantRow extends ConsumerWidget {
  final String peerId;
  final bool isSelf;
  final bool canKick;
  const _ParticipantRow({
    super.key,
    required this.peerId,
    required this.isSelf,
    required this.canKick,
  });

  static const double _avatar = 28;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final name = isSelf ? 'You' : conferenceDisplayName(ref, peerId);
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    // Self reads the dedicated local flag: the set is device-id keyed, so a
    // self membership test silently misses (see [vcLocalSpeakingProvider]).
    final speaking = isSelf
        ? ref.watch(vcLocalSpeakingProvider)
        : ref.watch(vcSpeakingProvider.select((s) => s.contains(peerId)));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        children: [
          SpeakingRing(
            speaking: speaking,
            color: callRingColor(hollow, isSelf: isSelf, master: master),
            radius: hollow.radiusMd,
            child: HollowAvatar(
              peerId: master,
              size: _avatar,
              semanticLabel: name,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              name,
              style:
                  HollowTypography.label.copyWith(color: hollow.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canKick)
            HollowIconButton(
              icon: LucideIcons.userMinus,
              label: 'Remove $name from the meeting',
              tooltip: 'Remove from meeting',
              size: 28,
              onPressed: () => _confirmKick(context, ref, name),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmKick(
      BuildContext context, WidgetRef ref, String name) async {
    final notifier = ref.read(conferenceProvider.notifier);
    final confirmed = await showHollowConfirm(
      context: context,
      title: 'Remove from meeting?',
      message: '$name will be removed and can only rejoin through the '
          'waiting room.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed) await notifier.kick(peerId);
  }
}

class _ConferenceCallArea extends ConsumerWidget {
  final ConferenceState conf;
  final String meetingName;
  const _ConferenceCallArea({required this.conf, required this.meetingName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final serverId = conf.activeServerId;
    final inThisCall = ref.watch(voiceChannelProvider.select((s) =>
        s.currentServerId == serverId &&
        s.currentChannelId == kConferenceChannelId));
    // The same stage and bar as a voice room (D1). Leave on the bar routes
    // through the meeting, never the bare voice leg.
    if (inThisCall) {
      return CallStage(
        key: ValueKey('conf-stage:$serverId'),
        source: VcCallStageSource(
            serverId: serverId, channelId: kConferenceChannelId),
      );
    }
    return ColoredBox(
      color: hollow.background,
      child: const Center(
        child: HollowEmptyState(title: 'Joining the meeting'),
      ),
    );
  }
}

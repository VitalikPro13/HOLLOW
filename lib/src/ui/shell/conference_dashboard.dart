import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/voice_channel_pane.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
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

/// Display name for a (possibly device-level) peer id: collapse device→master
/// first, then resolve through the profile cache.
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

/// Desktop center-tab surface for the Conferences feature: room manager,
/// joiner lobby, and the in-meeting call surface (Archive/Share tab pattern).
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

    // Internal view transitions (rooms ↔ lobby ↔ denied ↔ call) fade like
    // every other panel — same switcher pattern the shell uses for tabs.
    return AnimatedSwitcher(
      duration: HollowDurations.normal,
      switchInCurve: HollowCurves.enter,
      switchOutCurve: HollowCurves.exit,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.topCenter,
          children: [
            ...previousChildren,
            ?currentChild,
          ],
        );
      },
      child: KeyedSubtree(
        key: ValueKey(_viewKey(conf)),
        child: _buildView(context, conf),
      ),
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
          break; // Inconsistent transient — fall through to the room list.
      }
    }

    return Container(
      color: hollow.background,
      child: Column(
        children: [
          _buildHeader(hollow, conf),
          Expanded(
            child: conf.rooms.isEmpty
                ? _buildEmptyState(hollow)
                : _buildRoomList(conf),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(HollowTheme hollow, ConferenceState conf) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          Text('Conferences',
              style: HollowTypography.heading
                  .copyWith(color: hollow.textPrimary)),
          const SizedBox(width: HollowSpacing.sm),
          if (conf.rooms.isNotEmpty)
            Text(
              '${conf.rooms.length} ${conf.rooms.length == 1 ? 'room' : 'rooms'}',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary),
            ),
          const Spacer(),
          HollowButton.ghost(
            compact: true,
            icon: const Icon(LucideIcons.logIn, size: 14),
            onPressed: () => showJoinConferenceDialog(context),
            child: const Text('Join Meeting'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            compact: true,
            icon: const Icon(LucideIcons.plus, size: 14),
            onPressed: () => showConferenceRoomFormDialog(context),
            child: const Text('Create Room'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(HollowTheme hollow) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.video,
              size: 48, color: hollow.textSecondary.withValues(alpha: 0.4)),
          const SizedBox(height: HollowSpacing.lg),
          Text('No conference rooms yet',
              style: HollowTypography.heading
                  .copyWith(color: hollow.textSecondary)),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Create a room and share its link to meet anyone — '
            'no server or friendship needed.',
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildRoomList(ConferenceState conf) {
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        for (final room in conf.rooms) ...[
          _RoomCard(room: room),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ],
    );
  }
}

// ── Room card ──────────────────────────────────────────────────────────────

class _RoomCard extends ConsumerWidget {
  final ConferenceRoom room;
  const _RoomCard({required this.room});

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return Container(
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: hollow.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: Icon(LucideIcons.video, size: 20, color: hollow.accent),
          ),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  room.name,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      'Created ${_formatDate(room.createdAt)}',
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textSecondary),
                    ),
                    if (room.waitingRoom) ...[
                      const SizedBox(width: HollowSpacing.sm),
                      _badge(hollow, LucideIcons.doorOpen, 'Waiting room'),
                    ],
                    if (room.hasAccessCode) ...[
                      const SizedBox(width: HollowSpacing.sm),
                      _badge(hollow, LucideIcons.keyRound, 'Access code'),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            compact: true,
            icon: const Icon(LucideIcons.link, size: 14),
            onPressed: () => _copyLink(context),
            child: const Text('Copy link'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            compact: true,
            icon: const Icon(LucideIcons.video, size: 14),
            onPressed: () =>
                ref.read(conferenceProvider.notifier).startMeeting(room),
            child: const Text('Start meeting'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowTooltip(
            message: 'Edit room',
            child: HollowPressable(
              semanticLabel: 'Edit room ${room.name}',
              onTap: () => showConferenceRoomFormDialog(context, room: room),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.pencil,
                  size: 16, color: hollow.textSecondary),
            ),
          ),
          HollowTooltip(
            message: 'Delete room',
            child: HollowPressable(
              semanticLabel: 'Delete room ${room.name}',
              onTap: () => _confirmDelete(context, ref),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.trash2,
                  size: 16, color: hollow.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(HollowTheme hollow, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: hollow.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: hollow.accentText),
          const SizedBox(width: 3),
          Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: hollow.accentText,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  void _copyLink(BuildContext context) {
    Clipboard.setData(ClipboardData(text: room.inviteLink));
    HollowToast.show(context, 'Invite link copied',
        type: HollowToastType.success);
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
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
}

// ── Create/edit room dialog ────────────────────────────────────────────────

class _RoomFormDialog extends ConsumerStatefulWidget {
  final ConferenceRoom? room;
  const _RoomFormDialog({this.room});

  @override
  ConsumerState<_RoomFormDialog> createState() => _RoomFormDialogState();
}

class _RoomFormDialogState extends ConsumerState<_RoomFormDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _codeController;
  late bool _waitingRoom;
  bool _removeCode = false;
  bool _saving = false;

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

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    final notifier = ref.read(conferenceProvider.notifier);
    final code = _codeController.text.trim();
    if (_isEdit) {
      // COALESCE convention: null keeps the existing code, '' clears it.
      final String? accessCode =
          _removeCode ? '' : (code.isEmpty ? null : code);
      await notifier.updateRoom(
        confId: widget.room!.confId,
        name: name,
        waitingRoom: _waitingRoom,
        accessCode: accessCode,
        broadcastMode: widget.room!.broadcastMode,
      );
    } else {
      await notifier.createRoom(
        name: name,
        waitingRoom: _waitingRoom,
        accessCode: code,
      );
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasCode = widget.room?.hasAccessCode ?? false;

    return HollowDialog(
      title: _isEdit ? 'Edit Room' : 'Create Room',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Room name',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary)),
          const SizedBox(height: HollowSpacing.xs),
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
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Waiting room',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary)),
                    Text(
                      'Approve each joiner before they enter',
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textSecondary),
                    ),
                  ],
                ),
              ),
              HollowToggle(
                value: _waitingRoom,
                semanticLabel: 'Waiting room',
                onChanged: (v) => setState(() => _waitingRoom = v),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          Text('Access code (optional)',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary)),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _codeController,
            hintText: _isEdit && hasCode && !_removeCode
                ? 'Unchanged — type to replace'
                : 'Leave empty for none',
            maxLength: 64,
            showCounter: false,
          ),
          if (_isEdit && hasCode) ...[
            const SizedBox(height: HollowSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Remove access code',
                    style: HollowTypography.body
                        .copyWith(color: hollow.textPrimary),
                  ),
                ),
                HollowToggle(
                  value: _removeCode,
                  semanticLabel: 'Remove access code',
                  onChanged: (v) => setState(() => _removeCode = v),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed:
              _nameController.text.trim().isEmpty || _saving ? null : _submit,
          child: Text(_isEdit ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}

// ── Access code prompt ─────────────────────────────────────────────────────

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

class _JoinConferenceDialogState extends ConsumerState<_JoinConferenceDialog> {
  static final _idRe = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _join() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
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
    Navigator.of(context).pop();
    unawaited(ref
        .read(conferenceProvider.notifier)
        .requestJoin(confId)
        .catchError((_) {}));
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Join a Meeting',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Paste a meeting invite link or its id.',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _controller,
            hintText: 'hollow://conference/… or meeting id',
            autofocus: true,
            onSubmitted: (_) => _join(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: HollowSpacing.sm),
            Text(
              _error!,
              style:
                  HollowTypography.caption.copyWith(color: hollow.error),
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _join,
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
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Access Code',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This meeting requires an access code.',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
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

// ── Joiner lobby ───────────────────────────────────────────────────────────

class _LobbyView extends ConsumerWidget {
  final ConferenceState conf;
  const _LobbyView({required this.conf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final hostName = conf.hostName;

    return Container(
      color: hollow.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (conf.hostPeerId != null)
              HollowAvatar(
                // LobbyInfo carries the host's DEVICE id (the WS sender) —
                // profiles/avatars are keyed by their MASTER.
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
              // LobbyInfo is the host's reply to our knock — until it arrives
              // the meeting hasn't started (we auto re-knock when it does).
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
}

// ── Joiner denied ──────────────────────────────────────────────────────────

class _DeniedView extends ConsumerWidget {
  final ConferenceState conf;
  const _DeniedView({required this.conf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final wrongCode = conf.denyReason == 'wrong_code';

    return Container(
      color: hollow.background,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.doorClosed,
                size: 48, color: hollow.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: HollowSpacing.lg),
            Text(
              conferenceDenyMessage(conf.denyReason),
              style: HollowTypography.heading
                  .copyWith(color: hollow.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.xl),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                HollowButton.ghost(
                  onPressed: () =>
                      ref.read(conferenceProvider.notifier).leaveMeeting(),
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
          ],
        ),
      ),
    );
  }

  Future<void> _retryWithCode(BuildContext context, WidgetRef ref) async {
    final confId = conf.activeConfId;
    if (confId == null) return;
    final code = await promptConferenceAccessCode(context);
    if (code == null || code.isEmpty) return;
    await ref
        .read(conferenceProvider.notifier)
        .requestJoin(confId, accessCode: code);
  }
}

// ── In-call surface ────────────────────────────────────────────────────────

class _CallView extends ConsumerWidget {
  final ConferenceState conf;
  const _CallView({required this.conf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final meetingName = conf.isHost
        ? (conf.roomById(conf.activeConfId!)?.name ?? 'Meeting')
        : (conf.hostName != null && conf.hostName!.isNotEmpty
            ? "${conf.hostName}'s meeting"
            : 'Meeting');

    return Container(
      color: hollow.background,
      child: Column(
        children: [
          _buildHeader(context, ref, hollow, meetingName),
          Expanded(
            child: Stack(
              children: [
                _ConferenceCallArea(conf: conf, meetingName: meetingName),
                // Meeting management drawer — the chat drawer's mirror twin
                // on the LEFT edge: waiting room, participants, kick, search.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: _ManageDrawer(conf: conf),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WidgetRef ref, HollowTheme hollow,
      String meetingName) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.video, size: 18, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              meetingName,
              style: HollowTypography.heading
                  .copyWith(color: hollow.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (conf.isHost) ...[
            HollowButton.ghost(
              compact: true,
              icon: const Icon(LucideIcons.link, size: 14),
              onPressed: () {
                final link = webConferenceInviteLink(conf.activeConfId!);
                Clipboard.setData(ClipboardData(text: link));
                HollowToast.show(context, 'Invite link copied',
                    type: HollowToastType.success);
              },
              child: const Text('Copy link'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.danger(
              compact: true,
              onPressed: () =>
                  ref.read(conferenceProvider.notifier).endMeeting(),
              child: const Text('End meeting'),
            ),
          ] else
            HollowButton.ghost(
              compact: true,
              icon: const Icon(LucideIcons.phoneOff, size: 14),
              onPressed: () =>
                  ref.read(conferenceProvider.notifier).leaveMeeting(),
              child: const Text('Leave'),
            ),
        ],
      ),
    );
  }
}

// ── Meeting management drawer (waiting room + participants + kick) ──────────

/// The chat drawer's mirror twin on the LEFT edge of the call surface:
/// chevron toggle + slide-in panel with a search filter, the host's waiting
/// room (admit/decline), and the participant roster (kick for the host).
/// Auto-opens when a knock arrives so the host never misses one.
class _ManageDrawer extends ConsumerStatefulWidget {
  final ConferenceState conf;
  const _ManageDrawer({required this.conf});

  @override
  ConsumerState<_ManageDrawer> createState() => _ManageDrawerState();
}

class _ManageDrawerState extends ConsumerState<_ManageDrawer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setOpen(bool open) {
    if (_open == open) return;
    setState(() => _open = open);
    if (open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final pending = ref.watch(
        conferenceProvider.select((s) => s.isHost ? s.waiting.length : 0));

    // A knock deserves attention: pop the drawer open for the host.
    ref.listen(
        conferenceProvider.select((s) => s.isHost ? s.waiting.length : 0),
        (prev, next) {
      if (prev != null && next > prev) _setOpen(true);
    });

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AnimatedBuilder(
          animation: _curved,
          builder: (context, child) {
            if (_curved.value == 0.0) return const SizedBox.shrink();
            return ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: _curved.value,
                child: FadeTransition(opacity: _curved, child: child),
              ),
            );
          },
          child: Container(
            width: 300,
            decoration: BoxDecoration(
              color: hollow.surface.withValues(alpha: 0.88),
              border: Border(
                right: BorderSide(color: hollow.border.withValues(alpha: 0.5)),
              ),
            ),
            child: _ManagePanelContent(conf: widget.conf),
          ),
        ),
        GestureDetector(
          onTap: () => _setOpen(!_open),
          child: Semantics(
            label: _open ? 'Hide meeting panel' : 'Show meeting panel',
            button: true,
            child: Container(
              width: 24,
              height: 48,
              decoration: BoxDecoration(
                color: hollow.surface.withValues(alpha: 0.88),
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(8),
                ),
                border: Border(
                  right: BorderSide(
                      color: hollow.border.withValues(alpha: 0.5)),
                  top: BorderSide(
                      color: hollow.border.withValues(alpha: 0.5)),
                  bottom: BorderSide(
                      color: hollow.border.withValues(alpha: 0.5)),
                ),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Icon(
                    _open ? LucideIcons.chevronLeft : LucideIcons.users,
                    size: 14,
                    color: hollow.textSecondary,
                  ),
                  if (!_open && pending > 0)
                    Positioned(
                      top: 4,
                      right: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: hollow.accent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '$pending',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.background,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ManagePanelContent extends ConsumerStatefulWidget {
  final ConferenceState conf;
  const _ManagePanelContent({required this.conf});

  @override
  ConsumerState<_ManagePanelContent> createState() =>
      _ManagePanelContentState();
}

class _ManagePanelContentState extends ConsumerState<_ManagePanelContent> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _matches(String name, String peerId) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return name.toLowerCase().contains(q) ||
        peerId.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final conf = ref.watch(conferenceProvider);
    final vcState = ref.watch(voiceChannelProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final links = ref.watch(deviceLinkProvider);

    final participants = <String>{
      localPeerId,
      ...vcState.getParticipants(conf.activeServerId, kConferenceChannelId),
    }.where((p) => p.isNotEmpty).toList();

    final waiting = conf.isHost
        ? conf.waiting
            .where((w) => _matches(w.displayName, w.peerId))
            .toList()
        : const <WaitingEntry>[];
    final shownParticipants = participants.where((p) {
      final name =
          p == localPeerId ? 'You' : conferenceDisplayName(ref, p);
      return _matches(name, p);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.md, HollowSpacing.md, HollowSpacing.md, 0),
          child: HollowTextField(
            controller: _searchController,
            hintText: 'Search people',
            isDense: true,
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(HollowSpacing.md),
            children: [
              if (waiting.isNotEmpty) ...[
                _sectionLabel(hollow, 'Waiting Room (${waiting.length})'),
                for (final entry in waiting)
                  _WaitingRow(entry: entry, links: links),
                const SizedBox(height: HollowSpacing.md),
              ],
              _sectionLabel(
                  hollow, 'Participants (${shownParticipants.length})'),
              for (final peerId in shownParticipants)
                _ParticipantRow(
                  peerId: peerId,
                  isSelf: peerId == localPeerId,
                  canKick: conf.isHost && peerId != localPeerId,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(HollowTheme hollow, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Text(
        text,
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _WaitingRow extends ConsumerWidget {
  final WaitingEntry entry;
  final DeviceLinkState links;
  const _WaitingRow({required this.entry, required this.links});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final shortId = entry.peerId.length > 10
        ? '${entry.peerId.substring(0, 10)}…'
        : entry.peerId;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        children: [
          HollowAvatar(
            // Collapse device→master: the knock arrives from a DEVICE id,
            // but profiles/avatars are keyed by the person's master.
            peerId: links.identityOf(entry.peerId),
            size: 28,
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
                        style: HollowTypography.bodySmall.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (entry.isFriend) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: HollowSpacing.xs, vertical: 1),
                        decoration: BoxDecoration(
                          color: hollow.success.withValues(alpha: 0.15),
                          borderRadius:
                              BorderRadius.circular(hollow.radiusSm),
                        ),
                        child: Text(
                          'Friend',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.success,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
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
          HollowTooltip(
            message: 'Decline',
            child: HollowPressable(
              semanticLabel: 'Decline join request',
              onTap: () =>
                  ref.read(conferenceProvider.notifier).deny(entry.peerId),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.x, size: 16, color: hollow.error),
            ),
          ),
          HollowTooltip(
            message: 'Admit',
            child: HollowPressable(
              semanticLabel: 'Admit to meeting',
              onTap: () =>
                  ref.read(conferenceProvider.notifier).admit(entry.peerId),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child:
                  Icon(LucideIcons.check, size: 16, color: hollow.accent),
            ),
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
    required this.peerId,
    required this.isSelf,
    required this.canKick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final name = isSelf ? 'You' : conferenceDisplayName(ref, peerId);
    final speaking =
        ref.watch(vcSpeakingProvider.select((s) => s.contains(peerId)));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: speaking ? hollow.accent : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: HollowAvatar(
              peerId: ref.read(deviceLinkProvider).identityOf(peerId),
              size: 26,
              semanticLabel: name,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              name,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (canKick)
            HollowTooltip(
              message: 'Remove from meeting',
              child: HollowPressable(
                semanticLabel: 'Remove from meeting',
                onTap: () => _confirmKick(context, ref, name),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.userMinus,
                    size: 15, color: hollow.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmKick(
      BuildContext context, WidgetRef ref, String name) async {
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final hollow = HollowTheme.of(dialogContext);
        return HollowDialog(
          title: 'Remove from meeting?',
          content: Text(
            '$name will be removed and can only rejoin through the '
            'waiting room.',
            style:
                HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            HollowButton.danger(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await ref.read(conferenceProvider.notifier).kick(peerId);
    }
  }
}

// ── Call area (participants / video) ───────────────────────────────────────

class _ConferenceCallArea extends ConsumerWidget {
  final ConferenceState conf;
  final String meetingName;
  const _ConferenceCallArea({required this.conf, required this.meetingName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vcState = ref.watch(voiceChannelProvider);
    final serverId = conf.activeServerId;
    final inThisCall = vcState.currentServerId == serverId &&
        vcState.currentChannelId == kConferenceChannelId;

    // Video active — reuse the voice-channel pane's full-bleed screen-share /
    // camera-grid views wholesale (its right-side chat overlay is the ONE
    // conference chat; it only falls back to channel chat when no video is
    // up, and we never embed it in that state). The floating controls pill is
    // HIDDEN — its Disconnect tears down only the voice leg and strands the
    // meeting — and the conference's static controls bar sits below instead.
    if (inThisCall && (vcState.isScreenShareActive || vcState.isCameraActive)) {
      return Column(
        children: [
          Expanded(
            child: VoiceChannelPane(
              key: ValueKey('conf-vc:$serverId'),
              serverId: serverId,
              channelId: kConferenceChannelId,
              channelName: meetingName,
              hideControlsPill: true,
            ),
          ),
          _ConferenceControls(vcState: vcState),
        ],
      );
    }

    return _ParticipantsView(
        conf: conf, vcState: vcState, meetingName: meetingName);
  }
}

class _ParticipantsView extends ConsumerWidget {
  final ConferenceState conf;
  final VoiceChannelState vcState;
  final String meetingName;
  const _ParticipantsView({
    required this.conf,
    required this.vcState,
    required this.meetingName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final participants = <String>{
      localPeerId,
      ...vcState.getParticipants(conf.activeServerId, kConferenceChannelId),
    }.where((p) => p.isNotEmpty).toList();

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(HollowSpacing.lg),
                  child: Wrap(
                    spacing: HollowSpacing.lg,
                    runSpacing: HollowSpacing.lg,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final peerId in participants)
                        _ParticipantTile(
                          peerId: peerId,
                          isSelf: peerId == localPeerId,
                          vcState: vcState,
                        ),
                    ],
                  ),
                ),
              ),
            ),
            _ConferenceControls(vcState: vcState),
          ],
        ),
        // The SAME right-side chat drawer screen share uses — one conference
        // chat everywhere (RAM-only 'conf:...' key in channelChatProvider).
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: VcChatOverlay(
            serverId: conf.activeServerId,
            channelId: kConferenceChannelId,
            channelName: meetingName,
            initiallyOpen: true,
          ),
        ),
      ],
    );
  }
}

class _ParticipantTile extends ConsumerWidget {
  final String peerId;
  final bool isSelf;
  final VoiceChannelState vcState;
  const _ParticipantTile({
    required this.peerId,
    required this.isSelf,
    required this.vcState,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Membership select: only THIS tile rebuilds when its speaking flips.
    final speaking =
        ref.watch(vcSpeakingProvider.select((s) => s.contains(peerId)));
    final muted = isSelf
        ? vcState.isMuted
        : (vcState.peerAudioStates[peerId]?.isMuted ?? false);
    final name = isSelf ? 'You' : conferenceDisplayName(ref, peerId);

    return SizedBox(
      width: 96,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(hollow.radiusMd + 2),
                  border: Border.all(
                    color:
                        speaking ? hollow.accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: HollowAvatar(
                  peerId: ref.read(deviceLinkProvider).identityOf(peerId),
                  size: 56,
                  semanticLabel: name,
                ),
              ),
              if (muted)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: hollow.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: hollow.border),
                    ),
                    child:
                        Icon(LucideIcons.micOff, size: 10, color: hollow.error),
                  ),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            name,
            style: HollowTypography.caption
                .copyWith(color: hollow.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ConferenceControls extends ConsumerWidget {
  final VoiceChannelState vcState;
  const _ConferenceControls({required this.vcState});

  Future<void> _toggleScreenShare(BuildContext context, WidgetRef ref) async {
    if (vcState.isScreenSharing) {
      ref.read(voiceChannelProvider.notifier).stopScreenShare();
      return;
    }
    final selection = await showScreenShareDialog(context);
    if (selection != null && context.mounted) {
      ref.read(voiceChannelProvider.notifier).startScreenShare(
            selection.sourceId,
            selection.width,
            selection.height,
            selection.fps,
            shareAudio: selection.shareAudio,
            pid: selection.pid,
            windowHwnd: selection.windowHwnd,
          );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final vcNotifier = ref.read(voiceChannelProvider.notifier);

    Widget control({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      bool active = false,
    }) {
      return HollowTooltip(
        message: label,
        child: HollowPressable(
          semanticLabel: label,
          onTap: onTap,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: Icon(
            icon,
            size: 20,
            color: active ? hollow.error : hollow.textPrimary,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          control(
            icon: vcState.isMuted ? LucideIcons.micOff : LucideIcons.mic,
            label: vcState.isMuted ? 'Unmute' : 'Mute',
            active: vcState.isMuted,
            onTap: vcNotifier.toggleMute,
          ),
          const SizedBox(width: HollowSpacing.sm),
          control(
            icon: vcState.isDeafened
                ? LucideIcons.headphoneOff
                : LucideIcons.headphones,
            label: vcState.isDeafened ? 'Undeafen' : 'Deafen',
            active: vcState.isDeafened,
            onTap: vcNotifier.toggleDeafen,
          ),
          const SizedBox(width: HollowSpacing.sm),
          control(
            icon:
                vcState.isCameraOn ? LucideIcons.video : LucideIcons.videoOff,
            label:
                vcState.isCameraOn ? 'Turn camera off' : 'Turn camera on',
            active: vcState.isCameraOn,
            onTap: () => unawaited(
                vcNotifier.toggleCamera().catchError((_) {})),
          ),
          const SizedBox(width: HollowSpacing.sm),
          control(
            icon: LucideIcons.monitor,
            label: vcState.isScreenSharing
                ? 'Stop sharing'
                : 'Share your screen',
            active: vcState.isScreenSharing,
            onTap: () => unawaited(_toggleScreenShare(context, ref)),
          ),
        ],
      ),
    );
  }
}

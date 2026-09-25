import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// event_provider routes results here rather than opening a second dialog.
void Function(bool success, String? error)? _activeTwitchJoinCallback;

/// Called by event_provider on a TwitchJoinRejected event. Returns true when an
/// open dialog handled it, so the caller opens no new one.
bool handleTwitchJoinResult({required bool success, String? error}) {
  if (_activeTwitchJoinCallback != null) {
    _activeTwitchJoinCallback!(success, error);
    return true;
  }
  return false;
}

void showTwitchJoinDialog(
  BuildContext context, {
  required String serverId,
  required String channelId,
  required String channelName,
  required String serverName,
  required int minFollowDays,
  required bool requireSub,
  String? failureReason,
}) {
  showHollowDialog(
    context: context,
    builder: (_) => _TwitchJoinDialog(
      serverId: serverId,
      channelId: channelId,
      channelName: channelName,
      serverName: serverName,
      minFollowDays: minFollowDays,
      requireSub: requireSub,
      failureReason: failureReason,
    ),
  );
}

//// The "you cannot join this server" dialog, with the specific reason: a vague
/// failure here reads as a network problem. Information only, so it closes
/// from its title bar.
void showJoinRejectedDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  showHollowDialog(
    context: context,
    builder: (_) => HollowDialog(
      title: title,
      showClose: true,
      content: HollowDialogText(message),
    ),
  );
}

/// NSFW join-consent gate, shown when a server rejects a join with the
/// `nsfw_confirm:` reason. It covers every join entry point because the gate is
/// server-side reject-then-retry. [onProceed] sends the retry; the dialog stays
/// open while it runs and shows why if it fails.
Future<bool> showNsfwConfirmDialog(
  BuildContext context, {
  required String serverName,
  required Future<void> Function() onProceed,
}) {
  // Filled, not danger: joining destroys nothing.
  return showHollowConfirm(
    context: context,
    title: 'Sensitive content warning',
    message: '$serverName is marked NSFW. It may contain adult or disturbing '
        'content.\n\n'
        'This server is moderated only by its own moderators. Hollow does not '
        'host, review, or take responsibility for its content. By continuing '
        'you confirm that you are 18 or older.',
    confirmLabel: 'I am 18 or older, join',
    onConfirm: onProceed,
  );
}

/// The calls the Twitch join flow makes, behind one object a test can replace.
class TwitchJoinCalls {
  const TwitchJoinCalls();

  Future<bool> isConnected() => twitch_api.twitchIsConnected();

  Future<twitch_api.TwitchDeviceFlowResult> startDeviceFlow() =>
      twitch_api.twitchStartDeviceFlow();

  Future<void> pollForToken(String deviceCode, int intervalSecs) =>
      twitch_api.twitchPollForToken(
        deviceCode: deviceCode,
        intervalSecs: BigInt.from(intervalSecs),
      );

  Future<void> ensureToken() => twitch_api.twitchEnsureToken();

  Future<String> verifyFollow(String broadcasterId) =>
      twitch_api.twitchVerifyFollow(broadcasterId: broadcasterId);

  Future<void> joinServer(String serverId, String proof) =>
      crdt_api.joinServer(
        serverId: serverId,
        twitchProofJson: proof,
        nsfwConfirmed: false,
      );
}

final twitchJoinCallsProvider =
    Provider<TwitchJoinCalls>((ref) => const TwitchJoinCalls());

enum _JoinStep { checking, requirements, connect, verifying, success, failed }

class _TwitchJoinDialog extends ConsumerStatefulWidget {
  final String serverId;
  final String channelId;
  final String channelName;
  final String serverName;
  final int minFollowDays;
  final bool requireSub;
  final String? failureReason;

  const _TwitchJoinDialog({
    required this.serverId,
    required this.channelId,
    required this.channelName,
    required this.serverName,
    required this.minFollowDays,
    required this.requireSub,
    this.failureReason,
  });

  @override
  ConsumerState<_TwitchJoinDialog> createState() => _TwitchJoinDialogState();
}

class _TwitchJoinDialogState extends ConsumerState<_TwitchJoinDialog>
    with HollowDialogAction {
  // Checking first, so a connected account goes straight to Verifying instead
  // of flashing the requirements.
  _JoinStep _step = _JoinStep.checking;
  String? _error;

  String? _userCode;
  String? _verificationUri;

  TwitchJoinCalls get _calls => ref.read(twitchJoinCallsProvider);

  @override
  void initState() {
    super.initState();
    _activeTwitchJoinCallback = _onJoinResult;
    if (widget.failureReason != null) {
      _step = _JoinStep.failed;
      _error = widget.failureReason;
    } else {
      _checkAndProceed();
    }
  }

  @override
  void dispose() {
    if (_activeTwitchJoinCallback == _onJoinResult) {
      _activeTwitchJoinCallback = null;
    }
    super.dispose();
  }

  void _onJoinResult(bool success, String? error) {
    if (!mounted) return;
    if (success) {
      setState(() => _step = _JoinStep.success);
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) Navigator.of(context).pop();
      });
    } else {
      _fail(error ??
          "Your Twitch account doesn't meet this server's requirements.");
    }
  }

  void _fail(String sentence) {
    if (!mounted) return;
    setState(() {
      _step = _JoinStep.failed;
      _error = sentence;
    });
  }

  Future<void> _checkAndProceed() async {
    if (_step != _JoinStep.checking) {
      setState(() {
        _step = _JoinStep.checking;
        _error = null;
      });
    }
    bool connected;
    try {
      connected = await _calls.isConnected();
    } catch (_) {
      connected = false;
    }
    if (!mounted) return;
    if (connected) {
      await _verify();
    } else {
      setState(() => _step = _JoinStep.requirements);
    }
  }

  Future<void> _startConnect() async {
    final started = await runDialogAction(() async {
      final result = await _calls.startDeviceFlow();
      if (!mounted) return;
      setState(() {
        _step = _JoinStep.connect;
        _userCode = result.userCode;
        _verificationUri = result.verificationUri;
      });
      _pollForToken(result.deviceCode, result.intervalSecs.toInt());
    }, fallback: "Hollow couldn't reach Twitch. Try again in a moment.");
    // The next step shows its own waiting state.
    if (started && mounted) setState(() => actionRunning = false);
  }

  Future<void> _pollForToken(String deviceCode, int intervalSecs) async {
    try {
      await _calls.pollForToken(deviceCode, intervalSecs);
    } catch (e) {
      _fail(friendlyError(e,
          fallback: "Twitch didn't confirm the sign in. Try again."));
      return;
    }
    if (mounted) await _verify();
  }

  Future<void> _verify() async {
    setState(() => _step = _JoinStep.verifying);
    try {
      await _calls.ensureToken();
      // A blind-signed FOLLOW credential, never our own word for it: the shop
      // signs what Twitch said onto our master and the owner verifies it
      // offline against the pinned root. It names a channel, an age bucket and
      // a tier and nothing that identifies the Twitch account, which is why it
      // may also ride the join ring.
      final proof = await _calls.verifyFollow(widget.channelId);
      await _calls.joinServer(widget.serverId, proof);
      // Stays on verifying until event_provider calls back with the result.
    } catch (e) {
      _fail(friendlyError(e,
          fallback: "Hollow couldn't check your Twitch account. Try again."));
    }
  }

  String get _title => switch (_step) {
        _JoinStep.success => 'Joined ${widget.serverName}',
        _JoinStep.failed => "Couldn't join ${widget.serverName}",
        _ => 'Twitch verification',
      };

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final canCancel =
        _step == _JoinStep.requirements || _step == _JoinStep.connect;
    return HollowDialog(
      title: _title,
      width: 420,
      // A failure leaves nothing to confirm; success closes on its own.
      showClose: _step == _JoinStep.failed,
      busy: actionRunning,
      error: _step == _JoinStep.requirements ? actionError : null,
      content: _buildStepContent(hollow),
      actions: [
        if (canCancel)
          HollowButton.ghost(
            onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ..._primaryAction(),
      ],
    );
  }

  Widget _buildStepContent(HollowTheme hollow) {
    switch (_step) {
      case _JoinStep.checking:
        return _waiting(hollow, 'Checking your Twitch connection…');
      case _JoinStep.requirements:
        return _buildRequirements(hollow);
      case _JoinStep.connect:
        return _buildConnect(hollow);
      case _JoinStep.verifying:
        return _waiting(
          hollow,
          'Verifying your Twitch account…',
          detail: widget.channelName.isEmpty
              ? null
              : 'Checking that you follow ${widget.channelName}',
        );
      case _JoinStep.success:
        return _buildSuccess(hollow);
      case _JoinStep.failed:
        return HollowDialogText(_error ?? kGenericErrorSentence);
    }
  }

  Widget _buildRequirements(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowDialogText(
            '${widget.serverName} asks new members to verify with Twitch.'),
        const SizedBox(height: HollowSpacing.lg),
        _requirementRow(
          hollow,
          LucideIcons.userCheck,
          widget.minFollowDays > 0
              ? 'Follow ${widget.channelName} for at least '
                  '${widget.minFollowDays} days'
              : 'Follow ${widget.channelName}',
        ),
        if (widget.requireSub) ...[
          const SizedBox(height: HollowSpacing.sm),
          _requirementRow(
            hollow,
            LucideIcons.crown,
            'Subscribe to ${widget.channelName}',
          ),
        ],
        const SizedBox(height: HollowSpacing.lg),
        const HollowDialogText(
            'Connect your Twitch account so Hollow can check.'),
      ],
    );
  }

  Widget _requirementRow(HollowTheme hollow, IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
          ),
        ),
      ],
    );
  }

  Widget _buildConnect(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HollowDialogText(
            'Open Twitch and enter this code to connect your account.'),
        const SizedBox(height: HollowSpacing.lg),
        HollowCopyField(value: _userCode ?? '', name: 'Code', wrap: false),
        const SizedBox(height: HollowSpacing.lg),
        Row(
          children: [
            const HollowSpinner(),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                'Waiting for Twitch…',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _waiting(HollowTheme hollow, String text, {String? detail}) {
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowSpinner.medium(),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style:
                      HollowTypography.body.copyWith(color: hollow.textPrimary),
                ),
                if (detail != null)
                  Text(
                    detail,
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccess(HollowTheme hollow) {
    return Row(
      children: [
        Icon(LucideIcons.checkCircle, size: 20, color: hollow.success),
        const SizedBox(width: HollowSpacing.sm),
        const Expanded(
          child: HollowDialogText(
              "Your Twitch account meets this server's requirements."),
        ),
      ],
    );
  }

  List<Widget> _primaryAction() {
    switch (_step) {
      case _JoinStep.requirements:
        return [
          HollowButton.filled(
            onPressed: _startConnect,
            loading: actionRunning,
            icon: const Icon(BrandIcons.twitch),
            child: const Text('Connect Twitch'),
          ),
        ];
      case _JoinStep.connect:
        return [
          if (_verificationUri != null)
            HollowButton.filled(
              onPressed: () {
                final uri = Uri.tryParse(_verificationUri!);
                if (uri != null) launchUrl(uri).catchError((_) => false);
              },
              icon: const Icon(BrandIcons.twitch),
              child: const Text('Open Twitch'),
            ),
        ];
      case _JoinStep.failed:
        // A retry needs the channel to check against; a rejection relayed
        // without one only closes.
        return [
          if (widget.channelId.isNotEmpty)
            HollowButton.filled(
              onPressed: _checkAndProceed,
              child: const Text('Try again'),
            ),
        ];
      case _JoinStep.checking:
      case _JoinStep.verifying:
      case _JoinStep.success:
        return const [];
    }
  }
}

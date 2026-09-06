import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
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

/// The "you cannot join this server" dialog, with the specific reason: a vague
/// failure here reads as a network problem.
void showJoinRejectedDialog(
  BuildContext context, {
  required String title,
  required String message,
}) {
  showHollowDialog(
    context: context,
    builder: (ctx) {
      final hollow = HollowTheme.of(ctx);
      return HollowDialog(
        title: title,
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(LucideIcons.lock, size: 20, color: hollow.warning),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Text(
                message,
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        actions: [
          HollowButton.filled(
            onPressed: () => Navigator.of(ctx).pop(),
            compact: true,
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
}

/// NSFW join-consent gate, shown when a server rejects a join with the
/// `nsfw_confirm:` reason. It covers every join entry point because the gate is
/// server-side reject-then-retry.
void showNsfwConfirmDialog(
  BuildContext context, {
  required String serverName,
  required VoidCallback onProceed,
}) {
  showHollowDialog(
    context: context,
    builder: (ctx) {
      final hollow = HollowTheme.of(ctx);
      return HollowDialog(
        title: 'Sensitive content warning',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.alertTriangle, size: 20, color: hollow.warning),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: HollowTypography.body.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 13,
                        height: 1.4,
                      ),
                      children: [
                        TextSpan(
                          text: serverName,
                          style: TextStyle(
                            color: hollow.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const TextSpan(
                          text: ' is marked NSFW. It may contain adult or '
                              'disturbing content.',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              'This server is moderated only by its own moderators. Hollow does '
              'not host, review, or take responsibility for its content. '
              'Proceed at your own risk.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () {
              Navigator.of(ctx).pop();
              onProceed();
            },
            compact: true,
            child: const Text('Join'),
          ),
        ],
      );
    },
  );
}

enum _JoinStep { requirements, connect, verifying, success, failed }

class _TwitchJoinDialog extends StatefulWidget {
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
  State<_TwitchJoinDialog> createState() => _TwitchJoinDialogState();
}

class _TwitchJoinDialogState extends State<_TwitchJoinDialog> {
  _JoinStep _step = _JoinStep.requirements;
  String? _error;

  String? _userCode;
  String? _verificationUri;

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
      setState(() {
        _step = _JoinStep.failed;
        _error = error ?? 'Verification failed';
      });
    }
  }

  Future<void> _checkAndProceed() async {
    try {
      final connected = await twitch_api.twitchIsConnected();
      if (!mounted) return;
      if (connected) {
        _verify();
      } else {
        setState(() => _step = _JoinStep.requirements);
      }
    } catch (_) {
      if (mounted) setState(() => _step = _JoinStep.requirements);
    }
  }

  Future<void> _startConnect() async {
    setState(() => _step = _JoinStep.connect);
    try {
      final result = await twitch_api.twitchStartDeviceFlow();
      if (!mounted) return;
      setState(() {
        _userCode = result.userCode;
        _verificationUri = result.verificationUri;
      });
      _pollForToken(result.deviceCode, result.intervalSecs.toInt());
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _JoinStep.failed;
          _error = 'Failed to start Twitch auth: $e';
        });
      }
    }
  }

  Future<void> _pollForToken(String deviceCode, int intervalSecs) async {
    try {
      await twitch_api.twitchPollForToken(
        deviceCode: deviceCode,
        intervalSecs: BigInt.from(intervalSecs),
      );
      if (!mounted) return;
      _verify();
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _JoinStep.failed;
          _error = 'Twitch authorization failed: $e';
        });
      }
    }
  }

  Future<void> _verify() async {
    setState(() => _step = _JoinStep.verifying);
    try {
      await twitch_api.twitchEnsureToken();
      // A blind-signed FOLLOW credential, never our own word for it: the shop
      // signs what Twitch said onto our master and the owner verifies it
      // offline against the pinned root. It names a channel, an age bucket and
      // a tier and nothing that identifies the Twitch account, which is why it
      // may also ride the join ring.
      final proof = await twitch_api.twitchVerifyFollow(
        broadcasterId: widget.channelId,
      );
      crdt_api.joinServer(
        serverId: widget.serverId,
        twitchProofJson: proof,
        nsfwConfirmed: false,
      );
      // Stays on verifying until event_provider calls back with the join
      // result.
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = _JoinStep.failed;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final stepIndex = _step.index;
    final totalSteps = widget.failureReason != null ? 1 : 4;

    return HollowDialog(
      title: _step == _JoinStep.success
          ? 'Joined!'
          : _step == _JoinStep.failed
              ? 'Verification Failed'
              : 'Twitch Verification',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildStepContent(hollow),
          if (totalSteps > 1) ...[
            const SizedBox(height: HollowSpacing.xl),
            _buildDots(hollow, stepIndex, totalSteps),
          ],
        ],
      ),
      actions: _buildActions(hollow),
    );
  }

  Widget _buildStepContent(HollowTheme hollow) {
    switch (_step) {
      case _JoinStep.requirements:
        return _buildRequirements(hollow);
      case _JoinStep.connect:
        return _buildConnect(hollow);
      case _JoinStep.verifying:
        return _buildVerifying(hollow);
      case _JoinStep.success:
        return _buildSuccess(hollow);
      case _JoinStep.failed:
        return _buildFailed(hollow);
    }
  }

  Widget _buildRequirements(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
            children: [
              TextSpan(
                text: widget.serverName,
                style: TextStyle(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const TextSpan(text: ' requires Twitch verification to join.'),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        _requirementRow(
          hollow,
          LucideIcons.userCheck,
          widget.minFollowDays > 0
              ? 'Follow ${widget.channelName} for at least ${widget.minFollowDays} days'
              : 'Follow ${widget.channelName}',
        ),
        if (widget.requireSub) ...[
          const SizedBox(height: HollowSpacing.sm),
          _requirementRow(
            hollow,
            LucideIcons.crown,
            'Active subscription to ${widget.channelName}',
          ),
        ],
        const SizedBox(height: HollowSpacing.lg),
        Text(
          'You\'ll need to connect your Twitch account to verify.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _requirementRow(HollowTheme hollow, IconData icon, String text) {
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: hollow.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 14, color: hollow.accent),
        ),
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
    if (_userCode == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Starting Twitch authorization...',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Enter this code on Twitch:',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.lg),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: _userCode!));
            HollowToast.show(context, 'Code copied!');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.xl,
              vertical: HollowSpacing.md,
            ),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(
                color: hollow.accent.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _userCode!,
                  style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                    letterSpacing: 4,
                    fontSize: 24,
                  ),
                ),
                const SizedBox(width: HollowSpacing.md),
                Icon(LucideIcons.copy, size: 16, color: hollow.textSecondary),
              ],
            ),
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: hollow.textSecondary,
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Waiting for authorization...',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVerifying(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: hollow.accent,
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        Text(
          'Verifying your Twitch account...',
          style: HollowTypography.body.copyWith(color: hollow.textPrimary),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Checking follow status for ${widget.channelName}',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.checkCircle, size: 36, color: hollow.accent),
        const SizedBox(height: HollowSpacing.md),
        Text(
          'You\'re now in ${widget.serverName}!',
          style: HollowTypography.body.copyWith(
            color: hollow.accent,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildFailed(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.alertCircle, size: 20, color: hollow.error),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                'Could not join ${widget.serverName}',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.error.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.error.withValues(alpha: 0.2)),
          ),
          child: Text(
            _error ?? 'Unknown error',
            style: HollowTypography.body.copyWith(
              color: hollow.error,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDots(HollowTheme hollow, int current, int total) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final isActive = i <= current;
        return Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive
                ? hollow.accent
                : hollow.textSecondary.withValues(alpha: 0.3),
          ),
        );
      }),
    );
  }

  List<Widget> _buildActions(HollowTheme hollow) {
    switch (_step) {
      case _JoinStep.requirements:
        return [
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: _startConnect,
            icon: Icon(BrandIcons.twitch, size: 14, color: hollow.textPrimary),
            child: const Text('Connect Twitch'),
          ),
        ];
      case _JoinStep.connect:
        return [
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          if (_verificationUri != null)
            HollowButton.filled(
              onPressed: () {
                final uri = Uri.tryParse(_verificationUri!);
                if (uri != null) launchUrl(uri);
              },
              icon: Icon(BrandIcons.twitch, size: 14,
                  color: hollow.textPrimary),
              child: const Text('Open Twitch'),
            ),
        ];
      case _JoinStep.verifying:
        return [];
      case _JoinStep.success:
        return [];
      case _JoinStep.failed:
        return [
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ];
    }
  }
}

import 'package:flutter/material.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

void showTwitchDeviceCodeDialog(BuildContext context,
    {VoidCallback? onSuccess}) {
  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      return TwitchDeviceCodeDialog(onSuccess: onSuccess);
    },
  );
}

class TwitchDeviceCodeDialog extends StatefulWidget {
  final VoidCallback? onSuccess;

  const TwitchDeviceCodeDialog({super.key, this.onSuccess});

  @override
  State<TwitchDeviceCodeDialog> createState() =>
      _TwitchDeviceCodeDialogState();
}

class _TwitchDeviceCodeDialogState extends State<TwitchDeviceCodeDialog> {
  String? _userCode;
  String? _verificationUri;
  String? _error;
  bool _polling = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _startFlow();
  }

  void _retry() {
    setState(() {
      _error = null;
      _userCode = null;
      _verificationUri = null;
    });
    _startFlow();
  }

  Future<void> _startFlow() async {
    try {
      final result = await twitch_api.twitchStartDeviceFlow();
      if (!mounted) return;
      setState(() {
        _userCode = result.userCode;
        _verificationUri = result.verificationUri;
      });
      _pollForToken(result.deviceCode, result.intervalSecs.toInt());
    } catch (e) {
      if (mounted) setState(() => _error = twitchFlowErrorSentence(e));
    }
  }

  Future<void> _pollForToken(String deviceCode, int intervalSecs) async {
    setState(() => _polling = true);
    try {
      await twitch_api.twitchPollForToken(
        deviceCode: deviceCode,
        intervalSecs: BigInt.from(intervalSecs),
      );
      if (!mounted) return;
      setState(() {
        _done = true;
        _polling = false;
      });
      widget.onSuccess?.call();
      await Future.delayed(const Duration(milliseconds: 1200));
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = twitchFlowErrorSentence(e);
          _polling = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowDialog(
      title: 'Connect Twitch',
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            HollowDialogText(_error!)
          else if (_done)
            Row(
              children: [
                Icon(LucideIcons.checkCircle, size: 20, color: hollow.success),
                const SizedBox(width: HollowSpacing.sm),
                const Expanded(child: HollowDialogText('Twitch is connected.')),
              ],
            )
          else if (_userCode != null) ...[
            const HollowDialogText(
              'Open Twitch, sign in, and enter this code.',
            ),
            const SizedBox(height: HollowSpacing.lg),
            HollowCopyField(value: _userCode!, name: 'code'),
            if (_polling) ...[
              const SizedBox(height: HollowSpacing.md),
              Row(
                children: [
                  const HollowSpinner(),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      'Waiting for Twitch',
                      style: HollowTypography.bodySmall
                          .copyWith(color: hollow.textSecondary),
                    ),
                  ),
                ],
              ),
            ],
          ] else
            const Center(child: HollowSpinner.medium()),
        ],
      ),
      actions: [
        if (_error != null) ...[
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: _retry,
            child: const Text('Try again'),
          ),
        ] else if (!_done) ...[
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          if (_verificationUri != null)
            HollowButton.filled(
              onPressed: () {
                final uri = Uri.tryParse(_verificationUri!);
                if (uri != null) {
                  launchUrl(uri, mode: LaunchMode.externalApplication)
                      .catchError((_) => false);
                }
              },
              icon: const Icon(BrandIcons.twitch, size: 14),
              child: const Text('Open Twitch'),
            ),
        ],
      ],
    );
  }
}

/// The sentence for a failed Twitch sign-in: what happened on Twitch's side,
/// and that trying again starts over with a new code.
String twitchFlowErrorSentence(Object error) {
  final lower = error.toString().toLowerCase();
  if (lower.contains('denied')) {
    return 'The connection was turned down on Twitch. Try again if that was '
        'a mistake.';
  }
  if (lower.contains('expired') || lower.contains('device code')) {
    return 'That code ran out before Twitch saw it. Try again for a new one.';
  }
  // Logs the raw text; a network failure has no better words than these.
  friendlyError(error);
  return "Twitch didn't answer. Check your connection and try again.";
}

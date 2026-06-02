import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
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
      if (mounted) setState(() => _error = e.toString());
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
          _error = e.toString();
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
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_error != null) ...[
            Icon(LucideIcons.alertCircle, size: 32, color: hollow.error),
            const SizedBox(height: HollowSpacing.md),
            Text(
              _error!,
              style: HollowTypography.body.copyWith(color: hollow.error),
              textAlign: TextAlign.center,
            ),
          ] else if (_done) ...[
            Center(
              child: Column(
                children: [
                  Icon(LucideIcons.checkCircle,
                      size: 32, color: hollow.accent),
                  const SizedBox(height: HollowSpacing.md),
                  Text(
                    'Twitch connected!',
                    style:
                        HollowTypography.body.copyWith(color: hollow.accent),
                  ),
                ],
              ),
            ),
          ] else if (_userCode != null) ...[
            Text(
              'Enter this code on Twitch:',
              style: HollowTypography.body
                  .copyWith(color: hollow.textSecondary),
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
                      color: hollow.accent.withValues(alpha: 0.3)),
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
                    Icon(LucideIcons.copy,
                        size: 16, color: hollow.textSecondary),
                  ],
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.lg),
            if (_polling)
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
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary),
                  ),
                ],
              ),
          ] else ...[
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: hollow.textSecondary,
              ),
            ),
          ],
        ],
      ),
      actions: [
        if (_error != null)
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          )
        else if (_done)
          const SizedBox.shrink()
        else ...[
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          if (_verificationUri != null)
            HollowButton.filled(
              onPressed: () {
                final uri = Uri.tryParse(_verificationUri!);
                if (uri != null) {
                  launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: Icon(BrandIcons.twitch,
                  size: 14, color: hollow.textPrimary),
              child: const Text('Open Twitch'),
            ),
        ],
      ],
    );
  }
}

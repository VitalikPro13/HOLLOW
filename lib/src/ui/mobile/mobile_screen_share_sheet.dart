import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What the user picked in the mobile share sheet.
class MobileScreenShareChoice {
  final bool shareAudio;
  const MobileScreenShareChoice({required this.shareAudio});
}

/// Mobile pre-share options sheet (there's no source picking on a phone —
/// MediaProjection / ReplayKit capture THE screen; the OS consent dialog /
/// broadcast picker handles permission). Returns null when dismissed.
Future<MobileScreenShareChoice?> showMobileScreenShareSheet(
    BuildContext context) {
  final hollow = HollowTheme.of(context);
  return showModalBottomSheet<MobileScreenShareChoice>(
    context: context,
    backgroundColor: hollow.surface,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (_) => const _ScreenShareSheet(),
  );
}

class _ScreenShareSheet extends StatefulWidget {
  const _ScreenShareSheet();

  @override
  State<_ScreenShareSheet> createState() => _ScreenShareSheetState();
}

class _ScreenShareSheetState extends State<_ScreenShareSheet> {
  bool _shareAudio = true;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: HollowSpacing.sm),
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: hollow.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Row(
              children: [
                Icon(LucideIcons.monitor, size: 20, color: hollow.textPrimary),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  'Share your screen',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.lg),
            Row(
              children: [
                Icon(LucideIcons.volume2, size: 18, color: hollow.textPrimary),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Text(
                    'Share device audio',
                    style: HollowTypography.body
                        .copyWith(color: hollow.textPrimary),
                  ),
                ),
                HollowToggle(
                  value: _shareAudio,
                  onChanged: (v) => setState(() => _shareAudio = v),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              Platform.isAndroid
                  ? 'Your mic stays on — you can talk over the shared audio. '
                      'Apps that block capture (some DRM/streaming apps) stay '
                      'silent. Audio needs Android 10 or newer.'
                  : 'Your mic stays on — you can talk over the shared audio. '
                      'Pick Hollow in the broadcast menu and tap Start '
                      'Broadcast to begin.',
              style:
                  HollowTypography.caption.copyWith(color: hollow.textTertiary),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: HollowButton.ghost(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: HollowButton.filled(
                    onPressed: () => Navigator.pop(
                      context,
                      MobileScreenShareChoice(shareAudio: _shareAudio),
                    ),
                    child: const Text('Start sharing'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
          ],
        ),
      ),
    );
  }
}

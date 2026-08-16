import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/core/services/android_version.dart';
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
  void initState() {
    super.initState();
    // Android exposes SDK_INT only over the platform channel, so prime it and
    // rebuild once known. Below Android 10 the audio toggle locks (matching the
    // macOS-below-13 pattern) since AudioPlaybackCapture is unavailable there.
    if (Platform.isAndroid && AndroidScreenAudioSupport.sdkInt == null) {
      AndroidScreenAudioSupport.prime().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  String _audioHelperText(bool audioBlocked) {
    if (audioBlocked) {
      return 'Sharing device audio needs Android 10 or newer. Your screen '
          'still shares, and your mic stays on so you can talk.';
    }
    if (Platform.isAndroid) {
      return 'Your mic stays on, so you can talk over the shared audio. '
          'Apps that block capture (some DRM/streaming apps) stay silent.';
    }
    return 'Your mic stays on, so you can talk over the shared audio. '
        'Pick Hollow in the broadcast menu and tap Start Broadcast to begin.';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final audioBlocked = AndroidScreenAudioSupport.audioSendBlockedByOldOs;
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
                Icon(LucideIcons.volume2,
                    size: 18,
                    color: audioBlocked
                        ? hollow.textTertiary
                        : hollow.textPrimary),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Text(
                    'Share device audio',
                    style: HollowTypography.body.copyWith(
                        color: audioBlocked
                            ? hollow.textTertiary
                            : hollow.textPrimary),
                  ),
                ),
                HollowToggle(
                  value: audioBlocked ? false : _shareAudio,
                  onChanged: audioBlocked
                      ? null
                      : (v) => setState(() => _shareAudio = v),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              _audioHelperText(audioBlocked),
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
                      MobileScreenShareChoice(
                          shareAudio: audioBlocked ? false : _shareAudio),
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

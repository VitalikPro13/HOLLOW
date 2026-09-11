import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The desktop lock cover, as its own opaque route so it sits above every
/// dialog the app may have left open and nothing below it paints. The 32px
/// title bar lives above the Navigator and stays, so the window can still be
/// moved, minimised and closed while locked.
Route<void> lockCoverRoute() => PageRouteBuilder<void>(
      opaque: true,
      barrierDismissible: false,
      // Instant: a fade would show the conversation underneath on the way in.
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const LockCoverScreen(),
    );

class LockCoverScreen extends ConsumerWidget {
  const LockCoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final unlocking = ref.watch(appUnlockBusyProvider);

    return PopScope(
      // Only the password lifts this. Escape and the back gesture do nothing.
      canPop: false,
      child: Material(
        color: hollow.background,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.lock, size: 32, color: hollow.accent),
              const SizedBox(height: HollowSpacing.lg),
              Text(
                'Hollow is locked',
                style: HollowTypography.heading
                    .copyWith(color: hollow.textPrimary, fontSize: 16),
              ),
              const SizedBox(height: HollowSpacing.xs),
              // The password prompt sits on top of this and says what to type,
              // so the cover only carries what the prompt does not.
              Text(
                unlocking
                    ? 'Unlocking…'
                    : 'Messages and calls still reach you while it is locked.',
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary, fontSize: 12),
              ),
              if (unlocking) ...[
                const SizedBox(height: HollowSpacing.lg),
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: hollow.accent,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

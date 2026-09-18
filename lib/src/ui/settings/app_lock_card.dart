import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Desktop app lock card: how long until the window locks itself, and a way to
/// lock it right now.
///
/// [hasPassword] gates the whole card. Either protection mode qualifies, since
/// both have a password the unlock prompt can take; with none there would be
/// nothing to lift the lock with.
class AppLockCard extends ConsumerWidget {
  final bool hasPassword;

  const AppLockCard({super.key, required this.hasPassword});

  static String labelFor(int minutes) => switch (minutes) {
        0 => 'Off',
        60 => '1 hour',
        _ => '$minutes min',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    if (!hasPassword) {
      return Text(
        'Set a password above to lock Hollow.',
        style: HollowTypography.body
            .copyWith(color: hollow.textSecondary, fontSize: 12),
      );
    }

    final minutes = ref.watch(lockAfterMinutesProvider);
    final binding = (ref.watch(appShortcutsProvider).valueOrNull ??
        kAppShortcutDefaults)[AppShortcut.lockNow]!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Locks the window when you stop using it. Your app password opens '
          'it again, and Hollow keeps running while it is locked, so messages '
          'and calls still reach you.',
          style: HollowTypography.body
              .copyWith(color: hollow.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: HollowSpacing.md),
        Text(
          'Lock after',
          style: HollowTypography.body
              .copyWith(color: hollow.textPrimary, fontSize: 13),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            for (final choice in kLockAfterChoices)
              HollowChip(
                label: labelFor(choice),
                selected: minutes == choice,
                onTap: () => ref
                    .read(lockAfterMinutesProvider.notifier)
                    .setMinutes(choice),
              ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
        HollowButton.outline(
          onPressed: () => requestAppLock(ref, context),
          icon: const Icon(LucideIcons.lock, size: 16),
          child: const Text('Lock now'),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Shortcut: ${binding.display()}. Change it under Shortcuts.',
          style: HollowTypography.caption
              .copyWith(color: hollow.textSecondary, fontSize: 11),
        ),
      ],
    );
  }
}

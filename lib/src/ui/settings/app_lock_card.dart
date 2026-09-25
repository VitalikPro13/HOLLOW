import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// The "Lock after" row: how long until the window locks itself, and a way to
/// lock it right now.
///
/// [hasPassword] gates the whole row. Either protection mode qualifies, since
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
    if (!hasPassword) return const SizedBox.shrink();

    final minutes = ref.watch(lockAfterMinutesProvider);
    final binding = (ref.watch(appShortcutsProvider).valueOrNull ??
        kAppShortcutDefaults)[AppShortcut.lockNow]!;

    // Lock now stays a button: the shortcut alone is invisible to anyone who
    // never opens the Shortcuts page.
    // A phone has no shortcut, and it also locks after time in the background.
    final phone = Platform.isAndroid || Platform.isIOS;
    return SettingsRow(
      title: 'Lock after',
      subtitle: phone
          ? 'Also locks after ${kRelockAfterBackground.inSeconds} seconds '
              'away from Hollow'
          : '${binding.display()} locks it now',
      wideTrailing: true,
      trailing: Wrap(
        spacing: HollowSpacing.sm,
        runSpacing: HollowSpacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final choice in kLockAfterChoices)
            HollowChip(
              label: labelFor(choice),
              selected: minutes == choice,
              onTap: () => ref
                  .read(lockAfterMinutesProvider.notifier)
                  .setMinutes(choice)
                  .catchError((Object e) {
                if (context.mounted) {
                  HollowToast.show(context, friendlyError(e,
                          fallback: "Couldn't save the setting. Try again."),
                      type: HollowToastType.error);
                }
              }),
            ),
          HollowButton.ghost(
            compact: true,
            onPressed: () => requestAppLock(ref, context),
            child: const Text('Lock now'),
          ),
        ],
      ),
    );
  }
}

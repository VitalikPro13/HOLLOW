import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Shortcuts category of the desktop Settings dialog — a static reference of
/// the keyboard shortcuts, grouped General / Chat Input.
class ShortcutsSettingsView extends StatelessWidget {
  const ShortcutsSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return settingsCardList([
      const SettingsCard(
        title: 'General',
        children: [
          _ShortcutRow(label: 'Open Settings', shortcut: 'Ctrl + ,'),
          _ShortcutRow(label: 'Toggle Member Panel', shortcut: 'Ctrl + Shift + M'),
          _ShortcutRow(label: 'Quick Search', shortcut: 'Ctrl + K'),
          _ShortcutRow(label: 'Toggle Split View', shortcut: r'Ctrl + Shift + \'),
          _ShortcutRow(label: 'Focus Left Pane', shortcut: 'Ctrl + 1'),
          _ShortcutRow(label: 'Focus Right Pane', shortcut: 'Ctrl + 2'),
          _ShortcutRow(label: 'Zoom Interface In', shortcut: 'Ctrl + +'),
          _ShortcutRow(label: 'Zoom Interface Out', shortcut: 'Ctrl + −'),
          _ShortcutRow(label: 'Reset Zoom', shortcut: 'Ctrl + 0'),
        ],
      ),
      const SettingsCard(
        title: 'Chat Input',
        children: [
          _ShortcutRow(label: 'Send Message', shortcut: 'Enter'),
          _ShortcutRow(label: 'New Line', shortcut: 'Shift + Enter'),
          _ShortcutRow(label: 'Bold', shortcut: 'Ctrl + B'),
          _ShortcutRow(label: 'Italic', shortcut: 'Ctrl + I'),
          _ShortcutRow(label: 'Code', shortcut: 'Ctrl + E'),
          _ShortcutRow(label: 'Strikethrough', shortcut: 'Ctrl + Shift + X'),
          _ShortcutRow(label: 'Spoiler', shortcut: 'Ctrl + Shift + S'),
        ],
      ),
    ]);
  }
}

/// Single shortcut row: label on left, key badge on right.
class _ShortcutRow extends StatelessWidget {
  final String label;
  final String shortcut;

  const _ShortcutRow({
    required this.label,
    required this.shortcut,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xxs + 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          _KeyBadge(shortcut: shortcut),
        ],
      ),
    );
  }
}

/// Styled keyboard shortcut badge (e.g. "Ctrl + B").
class _KeyBadge extends StatelessWidget {
  final String shortcut;

  const _KeyBadge({required this.shortcut});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Split on " + " to render each key individually.
    final keys = shortcut.split(' + ');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < keys.length; i++) ...[
          if (i > 0)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: HollowSpacing.xxs),
              child: Text(
                '+',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary.withValues(alpha: 0.4),
                  fontSize: 9,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.xs + 2,
              vertical: HollowSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusSm - 2),
              border: Border.all(
                color: hollow.border,
              ),
            ),
            child: Text(
              keys[i],
              style: HollowTypography.mono.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

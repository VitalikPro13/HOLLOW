import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/settings/keybind_capture_field.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shortcuts category of the desktop Settings dialog; every row is rebindable
/// in place. The Voice rows edit the same providers as Audio & Video > Voice,
/// the rest live in [appShortcutsProvider], and Enter and Shift+Enter are
/// structural rather than shortcuts.
class ShortcutsSettingsView extends ConsumerStatefulWidget {
  const ShortcutsSettingsView({super.key});

  @override
  ConsumerState<ShortcutsSettingsView> createState() =>
      _ShortcutsSettingsViewState();
}

class _ShortcutsSettingsViewState extends ConsumerState<ShortcutsSettingsView> {
  @override
  void initState() {
    super.initState();
    // These providers may have cached defaults from before storage was ready,
    // so re-read from disk whenever the page opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(appShortcutsProvider);
      ref.invalidate(pttKeybindProvider);
      ref.invalidate(muteKeybindProvider);
      ref.invalidate(deafenKeybindProvider);
    });
  }

  void _setAppShortcut(AppShortcut shortcut, String serialized) {
    final binding = HotkeyBinding.parse(serialized);
    if (binding == null) return;
    // A bare typable key as an always-on shortcut would fire while typing a
    // message; F-keys and friends stay allowed.
    if (binding.isBare && binding.isTypableTrigger) {
      HollowToast.show(
          context,
          'Add a modifier (Ctrl/Shift/Alt). A bare letter or digit would '
          'trigger while typing.',
          type: HollowToastType.info);
      return;
    }
    ref
        .read(appShortcutsProvider.notifier)
        .setBinding(shortcut, serialized)
        .catchError((_) {
      if (mounted) {
        HollowToast.show(context, 'Could not save the shortcut.',
            type: HollowToastType.error);
      }
    });
  }

  Widget _appShortcutRow(HollowTheme hollow, AppShortcut shortcut) {
    final bindings =
        ref.watch(appShortcutsProvider).valueOrNull ?? kAppShortcutDefaults;
    final binding = bindings[shortcut]!;
    return _EditableRow(
      hollow: hollow,
      label: shortcut.label,
      serialized: binding.serialize(),
      isOverridden: binding != shortcut.defaultBinding,
      onChanged: (v) => _setAppShortcut(shortcut, v),
      onReset: () => ref
          .read(appShortcutsProvider.notifier)
          .reset(shortcut)
          .catchError((_) {}),
    );
  }

  Widget _voiceShortcutRow(
    HollowTheme hollow, {
    required String label,
    required AsyncNotifierProvider<KeybindNotifier, String> provider,
    required String fallback,
  }) {
    final raw = ref.watch(provider).valueOrNull ?? fallback;
    final serialized =
        HotkeyBinding.parse(raw) != null ? raw : fallback;
    return _EditableRow(
      hollow: hollow,
      label: label,
      serialized: serialized,
      isOverridden: serialized != fallback,
      // Voice bindings skip the bare-typable guard: they are live only in
      // calls, where bare keys are suppressed while typing.
      onChanged: (v) =>
          ref.read(provider.notifier).setBinding(v).catchError((_) {
        if (mounted) {
          HollowToast.show(context, 'Could not save the shortcut.',
              type: HollowToastType.error);
        }
      }),
      onReset: () =>
          ref.read(provider.notifier).setBinding(fallback).catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return settingsCardList([
      SettingsCard(
        title: 'General',
        children: [
          for (final s in const [
            AppShortcut.openSettings,
            AppShortcut.toggleMemberPanel,
            AppShortcut.quickSearch,
            AppShortcut.toggleSplitView,
            AppShortcut.focusLeftPane,
            AppShortcut.focusRightPane,
            AppShortcut.zoomIn,
            AppShortcut.zoomOut,
            AppShortcut.zoomReset,
          ])
            _appShortcutRow(hollow, s),
        ],
      ),
      SettingsCard(
        title: 'Voice (while in a call)',
        children: [
          _voiceShortcutRow(hollow,
              label: 'Push to talk (hold)',
              provider: pttKeybindProvider,
              fallback: 'ctrl+space'),
          _voiceShortcutRow(hollow,
              label: 'Toggle mute',
              provider: muteKeybindProvider,
              fallback: 'ctrl+shift+m'),
          _voiceShortcutRow(hollow,
              label: 'Toggle deafen',
              provider: deafenKeybindProvider,
              fallback: 'ctrl+shift+d'),
        ],
      ),
      SettingsCard(
        title: 'Chat Input',
        children: [
          const _FixedRow(label: 'Send message', shortcut: 'Enter'),
          const _FixedRow(label: 'New line', shortcut: 'Shift + Enter'),
          for (final s in const [
            AppShortcut.formatBold,
            AppShortcut.formatItalic,
            AppShortcut.formatCode,
            AppShortcut.formatStrikethrough,
            AppShortcut.formatSpoiler,
          ])
            _appShortcutRow(hollow, s),
        ],
      ),
    ]);
  }
}

/// Rebindable shortcut row. The reset affordance appears only when the binding
/// differs from its default.
class _EditableRow extends StatelessWidget {
  final HollowTheme hollow;
  final String label;
  final String serialized;
  final bool isOverridden;
  final ValueChanged<String> onChanged;
  final VoidCallback onReset;

  const _EditableRow({
    required this.hollow,
    required this.label,
    required this.serialized,
    required this.isOverridden,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
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
          if (isOverridden) ...[
            HollowTooltip(
              message: 'Reset to default',
              child: HollowPressable(
                onTap: onReset,
                semanticLabel: 'Reset $label shortcut to default',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xxs),
                child: Icon(
                  LucideIcons.rotateCcw,
                  size: 12,
                  color: hollow.textTertiary,
                ),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
          ],
          KeybindCaptureField(
            serialized: serialized,
            onChanged: onChanged,
            semanticLabel: 'Change $label shortcut',
          ),
        ],
      ),
    );
  }
}

/// Non-rebindable row, for the structural keys.
class _FixedRow extends StatelessWidget {
  final String label;
  final String shortcut;

  const _FixedRow({required this.label, required this.shortcut});

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

/// Styled keyboard shortcut badge, e.g. "Shift + Enter".
class _KeyBadge extends StatelessWidget {
  final String shortcut;

  const _KeyBadge({required this.shortcut});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

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

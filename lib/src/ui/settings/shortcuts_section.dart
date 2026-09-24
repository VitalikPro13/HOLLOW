import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_key_combo.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/keybind_capture_field.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Settings > Shortcuts; every row is rebindable in place. The call rows edit
/// the same providers as Audio & Video > Talking, the rest live in
/// [appShortcutsProvider], and Enter and Shift+Enter are structural rather
/// than shortcuts.
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
    // message; F-keys and friends stay allowed, and so is anything that lives
    // only inside one surface.
    if (!shortcut.surfaceScoped &&
        binding.isBare &&
        binding.isTypableTrigger) {
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

  Widget _appShortcutRow(AppShortcut shortcut) {
    final bindings =
        ref.watch(appShortcutsProvider).valueOrNull ?? kAppShortcutDefaults;
    final binding = bindings[shortcut]!;
    return _ShortcutRow(
      label: shortcut.label,
      onReset: binding != shortcut.defaultBinding
          ? () => ref
              .read(appShortcutsProvider.notifier)
              .reset(shortcut)
              .catchError((_) {})
          : null,
      control: KeybindCaptureField(
        serialized: binding.serialize(),
        onChanged: (v) => _setAppShortcut(shortcut, v),
        semanticLabel: 'Change ${shortcut.label} shortcut',
      ),
    );
  }

  Widget _voiceShortcutRow({
    required String label,
    required AsyncNotifierProvider<KeybindNotifier, String> provider,
    required String fallback,
  }) {
    final raw = ref.watch(provider).valueOrNull ?? fallback;
    final serialized = HotkeyBinding.parse(raw) != null ? raw : fallback;
    return _ShortcutRow(
      label: label,
      onReset: serialized != fallback
          ? () => ref
              .read(provider.notifier)
              .setBinding(fallback)
              .catchError((_) {})
          : null,
      control: KeybindCaptureField(
        serialized: serialized,
        // Voice bindings skip the bare-typable guard: they are live only in
        // calls, where bare keys are suppressed while typing.
        onChanged: (v) =>
            ref.read(provider.notifier).setBinding(v).catchError((_) {
          if (mounted) {
            HollowToast.show(context, 'Could not save the shortcut.',
                type: HollowToastType.error);
          }
        }),
        semanticLabel: 'Change $label shortcut',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Shortcuts',
      intro: "Click a key to change it. Keys in a call work only while "
          "you're in one.",
      children: [
        SettingsSection(
          title: 'General',
          children: [
            for (final s in const [
              AppShortcut.openSettings,
              AppShortcut.toggleMemberPanel,
              AppShortcut.quickSearch,
              AppShortcut.lockNow,
              AppShortcut.toggleFullscreen,
              AppShortcut.toggleSplitView,
              AppShortcut.focusLeftPane,
              AppShortcut.focusRightPane,
              AppShortcut.zoomIn,
              AppShortcut.zoomOut,
              AppShortcut.zoomReset,
            ])
              _appShortcutRow(s),
          ],
        ),
        SettingsSection(
          title: 'In a call',
          children: [
            _voiceShortcutRow(
                label: 'Push to talk (hold)',
                provider: pttKeybindProvider,
                fallback: 'ctrl+space'),
            _voiceShortcutRow(
                label: 'Mute',
                provider: muteKeybindProvider,
                fallback: 'ctrl+shift+m'),
            _voiceShortcutRow(
                label: 'Deafen',
                provider: deafenKeybindProvider,
                fallback: 'ctrl+shift+d'),
            const SettingsNote(
              'In a call these work system-wide on Windows and Linux (X11). '
              'On macOS and Wayland, only while Hollow is focused.',
            ),
          ],
        ),
        SettingsSection(
          title: 'Typing',
          children: [
            const _ShortcutRow(
                label: 'Send', control: HollowKeyCombo('Enter')),
            const _ShortcutRow(
                label: 'New line', control: HollowKeyCombo('Shift + Enter')),
            for (final s in const [
              AppShortcut.formatBold,
              AppShortcut.formatItalic,
              AppShortcut.formatCode,
              AppShortcut.formatStrikethrough,
              AppShortcut.formatSpoiler,
            ])
              _appShortcutRow(s),
          ],
        ),
        SettingsSection(
          title: 'Media viewer',
          children: [
            for (final s in const [
              AppShortcut.mediaZoomIn,
              AppShortcut.mediaZoomOut,
              AppShortcut.mediaZoomFit,
              AppShortcut.mediaActualSize,
              AppShortcut.mediaRotate,
              AppShortcut.mediaSaveAs,
              AppShortcut.mediaInfo,
              AppShortcut.mediaPlayPause,
              AppShortcut.mediaMute,
              AppShortcut.mediaLoop,
            ])
              _appShortcutRow(s),
          ],
        ),
      ],
    );
  }
}

/// One shortcut: its action, a reset when it differs from the default, and
/// the key. Denser than a settings row, since a page holds thirty of them.
class _ShortcutRow extends StatelessWidget {
  final String label;
  final Widget control;

  /// Null hides the reset (the binding is the default).
  final VoidCallback? onReset;

  const _ShortcutRow({
    required this.label,
    required this.control,
    this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? 48 : 36),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: (touch ? HollowTypography.bodyTouch : HollowTypography.body)
                  .copyWith(color: hollow.textPrimary),
            ),
          ),
          if (onReset != null) ...[
            HollowIconButton(
              icon: LucideIcons.rotateCcw,
              label: 'Reset $label shortcut to default',
              tooltip: 'Reset to default',
              size: touch ? 44 : 32,
              onPressed: onReset,
            ),
            const SizedBox(width: HollowSpacing.xs),
          ],
          control,
        ],
      ),
    );
  }
}

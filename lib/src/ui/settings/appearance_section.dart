import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_image_crop_route.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Settings > Appearance. Everything saves on change.
class AppearanceSettingsView extends ConsumerWidget {
  const AppearanceSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    final layoutMode = ref.watch(layoutModeProvider);
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final tray = ref.watch(minimizeToTrayProvider).valueOrNull ?? true;
    final cardStyle = ref.watch(profileCardStyleProvider);
    final hasBackground = ref.watch(backgroundProvider).hasBackground;
    return SettingsPage(
      title: 'Appearance',
      children: [
        SettingsSection(
          title: 'Theme',
          children: [
            SettingsChoiceRow<ThemeMode>(
              title: 'Theme',
              value: isDark ? ThemeMode.dark : ThemeMode.light,
              options: const [
                (ThemeMode.dark, 'Dark'),
                (ThemeMode.light, 'Light'),
              ],
              onChanged: (m) => ref.read(themeModeProvider.notifier).setMode(m),
            ),
            const _AccentColorPicker(),
            const _BackgroundImageRow(),
            if (hasBackground) const _DarkenRow(),
            const AmbientBackgroundToggle(),
          ],
        ),
        SettingsSection(
          title: isDesktop ? 'Layout' : 'Chat',
          children: [
            // A phone has one layout of its own.
            if (isDesktop)
              SettingsChoiceRow<LayoutMode>(
                title: 'Window layout',
                subtitle: layoutMode == LayoutMode.dock
                    ? 'Dock: friends on top, servers at the bottom'
                    : 'Classic: servers, channels, chat and members side by side',
                value: layoutMode,
                options: const [
                  (LayoutMode.dock, 'Dock'),
                  (LayoutMode.classic, 'Classic'),
                ],
                onChanged: (m) {
                  // Classic has no split view, and leaving one open strands the
                  // right pane invisibly until the user switches back.
                  if (m == LayoutMode.classic) {
                    ref.read(splitViewProvider.notifier).closeSplit();
                  }
                  ref.read(layoutModeProvider.notifier).setMode(m);
                },
              ),
            const MessageDisplayPicker(),
          ],
        ),
        if (isDesktop)
          SettingsSection(
            title: 'Window',
            children: [
              SettingsSwitchRow(
                title: 'Keep running when closed',
                subtitle: 'Closing the window leaves Hollow in the tray',
                value: tray,
                onChanged: (v) =>
                    ref.read(minimizeToTrayProvider.notifier).setEnabled(v),
              ),
              // Issue #54: one click can go straight to the full profile
              // instead of the small card with an expand button on it.
              SettingsSwitchRow(
                title: 'Open full profiles',
                subtitle: 'Clicking a name opens the whole profile, not the card',
                value: cardStyle == ProfileCardStyle.expanded,
                onChanged: (v) => ref
                    .read(profileCardStyleProvider.notifier)
                    .setStyle(v
                        ? ProfileCardStyle.expanded
                        : ProfileCardStyle.compact),
              ),
            ],
          ),
      ],
    );
  }
}

class _BackgroundImageRow extends ConsumerStatefulWidget {
  const _BackgroundImageRow();

  @override
  ConsumerState<_BackgroundImageRow> createState() =>
      _BackgroundImageRowState();
}

class _BackgroundImageRowState extends ConsumerState<_BackgroundImageRow> {
  bool _picking = false;

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.image);
      final file = result?.files.singleOrNull;
      if (file == null) return;
      final raw = await file.xFile.readAsBytes();
      if (!mounted) return;
      // A phone's background stands upright and crops on a full-screen route.
      final phone = Platform.isAndroid || Platform.isIOS;
      final crop = phone ? showMobileImageCrop : showImageCropDialog;
      final cropped = await crop(
        context: context,
        imageBytes: raw,
        aspectRatio: phone ? 9.0 / 16.0 : 16.0 / 9.0,
        title: 'Crop background',
      );
      if (cropped != null) {
        await ref
            .read(backgroundProvider.notifier)
            .setImage(cropped, name: file.name);
      }
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
        context,
        friendlyError(e,
            fallback: "Couldn't open that image. Try another one."),
        type: HollowToastType.error,
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = ref.watch(backgroundProvider);
    final has = bg.hasBackground;
    final name = bg.imageName;
    return SettingsRow(
      title: 'Background image',
      subtitle: has ? (name ?? 'Custom image') : 'None',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowButton.outline(
            compact: true,
            loading: _picking,
            onPressed: _pick,
            child: Text(has ? 'Change' : 'Choose'),
          ),
          if (has) ...[
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              compact: true,
              onPressed: () =>
                  ref.read(backgroundProvider.notifier).clearImage(),
              child: const Text('Remove'),
            ),
          ],
        ],
      ),
    );
  }
}

class _DarkenRow extends ConsumerWidget {
  const _DarkenRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opacity = ref.watch(backgroundProvider).panelOpacity;
    return SettingsSliderRow(
      title: 'Darken',
      subtitle: 'How much the panels cover the image',
      value: opacity,
      min: 0.4,
      max: 1.0,
      valueLabel: '${(opacity * 100).round()}%',
      onChanged: (v) => ref.read(backgroundProvider.notifier).setOpacity(v),
    );
  }
}

/// The hue bar and saved swatches. Too wide for a trailing edge, so it sits
/// under its title on every density.
class _AccentColorPicker extends ConsumerWidget {
  const _AccentColorPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final touch = SettingsDensity.touchOf(context);
    final currentHue = ref.watch(accentHueProvider);
    final presets = ref.watch(accentPresetsProvider);
    final swatch = touch ? 36.0 : 24.0;
    final unsaved = !presets.any((h) => (h - currentHue).abs() < 1) &&
        (currentHue - defaultAccentHue).abs() > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SettingsRow(
          title: 'Accent color',
          subtitle: 'Any hue on the bar, or one you saved',
        ),
        AccentHueSliderRow(
          hue: currentHue,
          height: swatch,
          trackHeight: 12,
          thumbRadius: 8,
          onChanged: (value) =>
              ref.read(accentHueProvider.notifier).setHue(value),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
          child: Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ColorSwatch(
                hue: defaultAccentHue,
                size: swatch,
                isSelected: (currentHue - defaultAccentHue).abs() < 1,
                label: 'Default',
                onTap: () => ref
                    .read(accentHueProvider.notifier)
                    .setHue(defaultAccentHue),
              ),
              for (final hue in presets)
                _ColorSwatch(
                  hue: hue,
                  size: swatch,
                  isSelected: (currentHue - hue).abs() < 1,
                  onTap: () =>
                      ref.read(accentHueProvider.notifier).setHue(hue),
                  onRemove: () => ref
                      .read(accentPresetsProvider.notifier)
                      .removePreset(hue),
                ),
              if (unsaved)
                HollowIconButton(
                  icon: LucideIcons.plus,
                  label: 'Save this color',
                  size: touch ? 44 : 32,
                  onPressed: () => ref
                      .read(accentPresetsProvider.notifier)
                      .addPreset(currentHue),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One accent swatch. A saved one is removed by right-click or long-press.
class _ColorSwatch extends StatelessWidget {
  final double hue;
  final double size;
  final bool isSelected;
  final String? label;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _ColorSwatch({
    required this.hue,
    required this.size,
    required this.isSelected,
    this.label,
    required this.onTap,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusXs);
    return HollowFocusRing(
      onActivate: onTap,
      borderRadius: radius,
      child: Semantics(
        button: true,
        selected: isSelected,
        label: label ?? 'Saved accent color',
        child: GestureDetector(
          onTap: onTap,
          onSecondaryTapUp: onRemove != null ? (_) => onRemove!() : null,
          onLongPress: onRemove,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: HollowTooltip(
              message: label ?? 'Right-click to remove',
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: accentFromHue(hue),
                  borderRadius: radius,
                  border: Border.all(
                    color: isSelected ? hollow.textPrimary : hollow.border,
                    width: isSelected ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

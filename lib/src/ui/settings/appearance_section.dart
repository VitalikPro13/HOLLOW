import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Appearance category of the desktop Settings dialog: theme (dark mode +
/// accent color), background image, and layout toggles. Everything here
/// auto-saves on change.
class AppearanceSettingsView extends ConsumerWidget {
  const AppearanceSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
    final layoutMode = ref.watch(layoutModeProvider);
    final invisible = ref.watch(invisibleModeProvider);
    final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final tray = ref.watch(minimizeToTrayProvider).valueOrNull ?? true;
    final cardStyle = ref.watch(profileCardStyleProvider);
    return settingsCardList([
      SettingsCard(
        title: 'Theme',
        children: [
          SettingsToggleRow(
            icon: isDark ? LucideIcons.moon : LucideIcons.sun,
            label: 'Dark mode',
            value: isDark,
            onChanged: (v) => ref
                .read(themeModeProvider.notifier)
                .setMode(v ? ThemeMode.dark : ThemeMode.light),
          ),
          const SizedBox(height: HollowSpacing.lg),
          _AccentColorPicker(hollow: hollow),
        ],
      ),
      SettingsCard(
        title: 'Background',
        children: [_BackgroundPicker(hollow: hollow)],
      ),
      SettingsCard(
        title: 'Layout',
        children: [
          // A two-way switch, not an on/off toggle: "Dock Mode off" gave no
          // hint that what you land in is the familiar Discord/Slack shell.
          Row(
            children: [
              Icon(LucideIcons.layoutDashboard,
                  size: 16, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Window layout',
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
                    ),
                    Text(
                      layoutMode == LayoutMode.dock
                          ? 'Dock: friends strip on top, dock bar at the bottom'
                          : 'Classic: server strip, channels, chat, members',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          TriStateSegment<LayoutMode>(
            value: layoutMode,
            options: const [
              (LayoutMode.dock, 'Dock'),
              (LayoutMode.classic, 'Classic'),
            ],
            onChanged: (m) {
              // Classic has no split view — leaving a split open would strand
              // the right pane invisibly until the user switched back.
              if (m == LayoutMode.classic) {
                ref.read(splitViewProvider.notifier).closeSplit();
              }
              ref.read(layoutModeProvider.notifier).setMode(m);
            },
          ),
          const SizedBox(height: HollowSpacing.md),
          SettingsToggleRow(
            icon: LucideIcons.eyeOff,
            label: 'Appear invisible',
            subtitle: 'Show as offline to other users',
            value: invisible,
            onChanged: (v) =>
                ref.read(invisibleModeProvider.notifier).setInvisible(v),
          ),
          if (isDesktop) ...[
            const SizedBox(height: HollowSpacing.md),
            SettingsToggleRow(
              icon: LucideIcons.minimize2,
              label: 'Minimize to tray',
              subtitle: 'Keep running in the background when closed',
              value: tray,
              onChanged: (v) =>
                  ref.read(minimizeToTrayProvider.notifier).setEnabled(v),
            ),
          ],
          if (isDesktop) ...[
            const SizedBox(height: HollowSpacing.md),
            // Issue #54: one click can go straight to the full profile
            // instead of the small card with an expand button on it.
            SettingsToggleRow(
              icon: LucideIcons.idCard,
              label: 'Open profiles expanded',
              subtitle: 'Clicking a user opens the full profile, not the card',
              value: cardStyle == ProfileCardStyle.expanded,
              onChanged: (v) => ref
                  .read(profileCardStyleProvider.notifier)
                  .setStyle(v
                      ? ProfileCardStyle.expanded
                      : ProfileCardStyle.compact),
            ),
          ],
        ],
      ),
    ]);
  }
}

/// Background image picker + panel opacity slider.
class _BackgroundPicker extends ConsumerWidget {
  final HollowTheme hollow;
  const _BackgroundPicker({required this.hollow});

  Future<void> _pickBackground(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final raw = await File(path).readAsBytes();
    if (!context.mounted) return;
    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: raw,
      aspectRatio: 16.0 / 9.0,
      title: 'Crop background',
    );
    if (cropped != null) {
      ref.read(backgroundProvider.notifier).setImage(cropped);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bg = ref.watch(backgroundProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label + buttons
        Row(
          children: [
            Icon(LucideIcons.image, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Background',
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            HollowButton.ghost(
              onPressed: () => _pickBackground(context, ref),
              compact: true,
              child: Text(bg.hasBackground ? 'Change' : 'Set image'),
            ),
            if (bg.hasBackground) ...[
              const SizedBox(width: HollowSpacing.xs),
              HollowButton.ghost(
                onPressed: () =>
                    ref.read(backgroundProvider.notifier).clearImage(),
                compact: true,
                child: const Text('Remove'),
              ),
            ],
          ],
        ),

        // Opacity slider (only when background is set)
        if (bg.hasBackground) ...[
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Text(
                'Darken',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 20,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      thumbColor: Colors.white,
                      activeTrackColor:
                          accentFromHue(ref.watch(accentHueProvider)),
                      inactiveTrackColor: hollow.border,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: bg.panelOpacity,
                      min: 0.4,
                      max: 1.0,
                      onChanged: (value) {
                        ref.read(backgroundProvider.notifier).setOpacity(value);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                '${(bg.panelOpacity * 100).round()}%',
                style: HollowTypography.mono.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Accent color picker — hue slider + preset swatches.
class _AccentColorPicker extends ConsumerStatefulWidget {
  final HollowTheme hollow;

  const _AccentColorPicker({required this.hollow});

  @override
  ConsumerState<_AccentColorPicker> createState() => _AccentColorPickerState();
}

class _AccentColorPickerState extends ConsumerState<_AccentColorPicker> {

  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;
    final currentHue = ref.watch(accentHueProvider);
    final presets = ref.watch(accentPresetsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label row with color preview
        Row(
          children: [
            Icon(LucideIcons.palette, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Accent color',
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            AccentHuePreviewBox(hue: currentHue, size: 18, radius: 4),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),

        // Hue slider (rainbow gradient)
        AccentHueSliderRow(
          hue: currentHue,
          height: 24,
          trackHeight: 14,
          thumbRadius: 9,
          onChanged: (value) {
            ref.read(accentHueProvider.notifier).setHue(value);
          },
        ),

        const SizedBox(height: HollowSpacing.sm),

        // Preset swatches row
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            // Default teal
            _ColorSwatch(
              hue: defaultAccentHue,
              isSelected: (currentHue - defaultAccentHue).abs() < 1,
              label: 'Default',
              onTap: () =>
                  ref.read(accentHueProvider.notifier).setHue(defaultAccentHue),
              hollow: hollow,
            ),
            // Saved presets
            for (final hue in presets)
              _ColorSwatch(
                hue: hue,
                isSelected: (currentHue - hue).abs() < 1,
                onTap: () =>
                    ref.read(accentHueProvider.notifier).setHue(hue),
                onRemove: () =>
                    ref.read(accentPresetsProvider.notifier).removePreset(hue),
                hollow: hollow,
              ),
            // Save current button
            if (!presets.any((h) => (h - currentHue).abs() < 1) &&
                (currentHue - defaultAccentHue).abs() > 1)
              GestureDetector(
                onTap: () => ref
                    .read(accentPresetsProvider.notifier)
                    .addPreset(currentHue),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: hollow.textSecondary.withValues(alpha: 0.4),
                        style: BorderStyle.solid,
                      ),
                    ),
                    child: Icon(
                      LucideIcons.plus,
                      size: 12,
                      semanticLabel: 'Save color preset',
                      color: hollow.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A small color swatch for preset selection.
class _ColorSwatch extends StatelessWidget {
  final double hue;
  final bool isSelected;
  final String? label;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final HollowTheme hollow;

  const _ColorSwatch({
    required this.hue,
    required this.isSelected,
    this.label,
    required this.onTap,
    this.onRemove,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return HollowFocusRing(
      onActivate: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Semantics(
        button: true,
        label: label ?? 'Accent color',
        child: GestureDetector(
          onTap: onTap,
          onSecondaryTapUp: onRemove != null ? (_) => onRemove!() : null,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: HollowTooltip(
              message: label ?? 'Right-click to remove',
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: accentFromHue(hue),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: isSelected
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.15),
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

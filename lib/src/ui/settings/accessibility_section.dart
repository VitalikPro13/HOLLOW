import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Settings > Accessibility: display size, reduce motion and reduce
/// transparency. Everything saves on change.
class AccessibilitySettingsView extends ConsumerWidget {
  const AccessibilitySettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final motion =
        ref.watch(reduceMotionProvider).valueOrNull ?? ReduceMotionMode.auto;
    final reduceTransparency =
        ref.watch(reduceTransparencyProvider).valueOrNull ?? false;
    final phone = Platform.isAndroid || Platform.isIOS;
    return SettingsPage(
      title: 'Accessibility',
      children: [
        SettingsSection(
          title: 'Size',
          children: [
            const InterfaceScaleControl(),
            const ChatTextScaleControl(),
            // A phone has no side panels, keyboard zoom or panel seams.
            if (phone)
              const SettingsNote(
                "Both add to your phone's own display and text size.",
              )
            else ...[
              const PanelScaleControl(),
              const SettingsNote(
                'Ctrl + and Ctrl − zoom the interface, Ctrl 0 resets it. All '
                "three add to your system's own scale.",
              ),
              // Panel widths are dragged, not set here, and the seam between
              // two panes is invisible until you know it is there.
              const SettingsNote(
                'Drag the edge between two panels to resize them. Double-click '
                'it to put it back.',
              ),
            ],
          ],
        ),
        SettingsSection(
          title: 'Motion and transparency',
          children: [
            SettingsChoiceRow<ReduceMotionMode>(
              title: 'Reduce motion',
              subtitle: 'Auto follows your system',
              value: motion,
              options: const [
                (ReduceMotionMode.auto, 'Auto'),
                (ReduceMotionMode.on, 'On'),
                (ReduceMotionMode.off, 'Off'),
              ],
              onChanged: (m) =>
                  ref.read(reduceMotionProvider.notifier).setMode(m),
            ),
            SettingsSwitchRow(
              title: 'Reduce transparency',
              subtitle: 'No blur or see-through panels',
              value: reduceTransparency,
              onChanged: (v) =>
                  ref.read(reduceTransparencyProvider.notifier).setEnabled(v),
            ),
          ],
        ),
      ],
    );
  }
}

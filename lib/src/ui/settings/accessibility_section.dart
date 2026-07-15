import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Accessibility category of the desktop Settings dialog: reduce motion
/// (tri-state Auto/On/Off) and reduce transparency. Auto-saves on change.
class AccessibilitySettingsView extends ConsumerWidget {
  const AccessibilitySettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final motion =
        ref.watch(reduceMotionProvider).valueOrNull ?? ReduceMotionMode.auto;
    final reduceTransparency =
        ref.watch(reduceTransparencyProvider).valueOrNull ?? false;
    return settingsCardList([
      SettingsCard(
        title: 'Motion',
        children: [
          Row(
            children: [
              Icon(LucideIcons.zap, size: 16, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reduce Motion',
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
                    ),
                    Text(
                      'Auto follows your system setting',
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
          TriStateSegment<ReduceMotionMode>(
            value: motion,
            options: const [
              (ReduceMotionMode.auto, 'Auto'),
              (ReduceMotionMode.on, 'On'),
              (ReduceMotionMode.off, 'Off'),
            ],
            onChanged: (m) =>
                ref.read(reduceMotionProvider.notifier).setMode(m),
          ),
        ],
      ),
      SettingsCard(
        title: 'Transparency',
        children: [
          SettingsToggleRow(
            icon: LucideIcons.square,
            label: 'Reduce Transparency',
            subtitle: 'Turn off background blur and glass effects',
            value: reduceTransparency,
            onChanged: (v) =>
                ref.read(reduceTransparencyProvider.notifier).setEnabled(v),
          ),
        ],
      ),
    ]);
  }
}

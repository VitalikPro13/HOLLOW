import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/imported_archives_view.dart';
import 'package:hollow/src/ui/archive/my_data_view.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// Archive dashboard — top-level tab with "My Data" and "Imported Archives" sub-tabs.
class ArchiveDashboard extends ConsumerWidget {
  const ArchiveDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final subTab = ref.watch(archiveSubTabProvider);

    return Container(
      color: hollow.background,
      child: Column(
        children: [
          // ── Top tab bar ──
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: hollow.border)),
            ),
            child: Row(
              children: [
                Text('Archive', style: HollowTypography.heading.copyWith(color: hollow.textPrimary)),
                const Spacer(),
                _SubTabPill(
                  label: 'My Data',
                  isSelected: subTab == ArchiveSubTab.myData,
                  onTap: () => ref.read(archiveSubTabProvider.notifier).state =
                      ArchiveSubTab.myData,
                ),
                const SizedBox(width: HollowSpacing.sm),
                _SubTabPill(
                  label: 'Imported Archives',
                  isSelected: subTab == ArchiveSubTab.importedArchives,
                  onTap: () => ref.read(archiveSubTabProvider.notifier).state =
                      ArchiveSubTab.importedArchives,
                ),
                const Spacer(),
              ],
            ),
          ),

          // ── Body ──
          Expanded(
            child: subTab == ArchiveSubTab.myData
                ? const MyDataView()
                : const ImportedArchivesView(),
          ),
        ],
      ),
    );
  }

}

/// Pill-shaped sub-tab button.
class _SubTabPill extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SubTabPill({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? hollow.accent.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(
            color: isSelected
                ? hollow.accent.withValues(alpha: 0.3)
                : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.body.copyWith(
            color: isSelected ? hollow.accent : hollow.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

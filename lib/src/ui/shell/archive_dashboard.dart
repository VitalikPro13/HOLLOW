import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/imported_archives_view.dart';
import 'package:hollow/src/ui/archive/my_data_view.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';

/// Archive dashboard, with the My Data and Imported Archives sub-tabs.
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
                HollowChip(
                  label: 'My Data',
                  selected: subTab == ArchiveSubTab.myData,
                  onTap: () => ref.read(archiveSubTabProvider.notifier).state =
                      ArchiveSubTab.myData,
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowChip(
                  label: 'Imported Archives',
                  selected: subTab == ArchiveSubTab.importedArchives,
                  onTap: () => ref.read(archiveSubTabProvider.notifier).state =
                      ArchiveSubTab.importedArchives,
                ),
                const Spacer(),
              ],
            ),
          ),

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


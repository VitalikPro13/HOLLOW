import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/archive/imported_archives_view.dart';
import 'package:hollow/src/ui/archive/my_data_view.dart';
import 'package:hollow/src/ui/archive/recovery_pool_dashboard.dart';
import 'package:hollow/src/ui/archive/vault_files_view.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/shell/place_header.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Archive place: what this device keeps (messages), what the servers keep
/// spread across members (vault files), and archives someone exported.
class ArchiveDashboard extends ConsumerWidget {
  const ArchiveDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final section = ref.watch(archiveSectionProvider);
    final pool = ref.watch(recoveryPoolProvider);
    final poolRunning = pool != null && pool.isActive && !pool.isPending;

    void show(ArchiveSection s) =>
        ref.read(archiveSectionProvider.notifier).state = s;

    return ColoredBox(
      color: hollow.background,
      child: Column(
        children: [
          PlaceHeader(
            title: 'Archive',
            tabs: [
              HollowChipTabs<ArchiveSection>(
                selected: section,
                onSelected: show,
                tabs: const [
                  HollowChipTab(
                      value: ArchiveSection.messages, label: 'Messages'),
                  HollowChipTab(
                      value: ArchiveSection.vault, label: 'Vault files'),
                  HollowChipTab(
                      value: ArchiveSection.imported, label: 'Imported'),
                ],
              ),
            ],
            actions: [
              if (section == ArchiveSection.vault && !poolRunning)
                HollowButton.ghost(
                  compact: true,
                  icon: const Icon(LucideIcons.logIn, size: 14),
                  onPressed: () => showJoinRecoveryPoolDialog(context),
                  child: const Text('Join a recovery pool'),
                ),
              if (section == ArchiveSection.imported) const LoadArchiveButton(),
            ],
          ),
          Expanded(
            child: switch (section) {
              ArchiveSection.messages => const MyDataView(),
              ArchiveSection.vault => poolRunning
                  ? const RecoveryPoolDashboard()
                  : const VaultFilesView(),
              ArchiveSection.imported => const ImportedArchivesView(),
            },
          ),
        ],
      ),
    );
  }
}

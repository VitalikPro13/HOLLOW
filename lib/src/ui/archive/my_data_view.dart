import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/archive/archive_conversation_list.dart';
import 'package:hollow/src/ui/archive/archive_message_viewer.dart';
import 'package:hollow/src/ui/archive/recovery_pool_dashboard.dart';
import 'package:hollow/src/ui/archive/vault_files_view.dart';

/// Two-panel layout for the "My Data" sub-tab: conversation list on the left,
/// read-only viewer or vault files on the right.
class MyDataView extends ConsumerWidget {
  const MyDataView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final innerTab = ref.watch(myDataInnerTabProvider);
    final recoveryPool = ref.watch(recoveryPoolProvider);

    final Widget rightPanel;
    if (innerTab == MyDataInnerTab.vaultFiles && recoveryPool != null && recoveryPool.isActive && !recoveryPool.isPending) {
      rightPanel = const RecoveryPoolDashboard();
    } else if (innerTab == MyDataInnerTab.vaultFiles) {
      rightPanel = const VaultFilesView();
    } else {
      rightPanel = const ArchiveMessageViewer();
    }

    return Row(
      children: [
        SizedBox(
          width: 280,
          child: Container(
            decoration: BoxDecoration(
              // Transparency-aware (#44): opaqueBackground is for fixed chrome
              // bars only.
              color: hollow.surface,
              border: Border(right: BorderSide(color: hollow.border)),
            ),
            child: const ArchiveConversationList(),
          ),
        ),
        Expanded(child: rightPanel),
      ],
    );
  }
}

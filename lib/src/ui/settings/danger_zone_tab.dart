import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Danger Zone tab: the owner sees Delete, everyone else sees Leave.
class DangerZoneTab extends ConsumerWidget {
  final ServerInfo server;

  const DangerZoneTab({super.key, required this.server});

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showHollowConfirm(
      context: context,
      title: 'Delete server',
      message: 'Are you sure you want to delete "${server.name}"?\n\n'
          'This action cannot be undone. All channels and messages will be '
          'permanently deleted.',
      confirmLabel: 'Delete server',
      destructive: true,
    );
    if (confirmed && context.mounted) await _deleteServer(context, ref);
  }

  Future<void> _deleteServer(BuildContext context, WidgetRef ref) async {
    try {
      await crdt_api.deleteServer(serverId: server.serverId);
      ref.read(serverSettingsOpenProvider.notifier).state = false;
      ref.read(selectedServerProvider.notifier).state = null;
      ref.read(selectedChannelProvider.notifier).state = null;
      ref.read(channelListProvider.notifier).clear();
      if (context.mounted) {
        HollowToast.show(
          context,
          'Server "${server.name}" deleted',
          type: HollowToastType.info,
        );
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(
          context,
          'Failed to delete server: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  Future<void> _confirmLeave(BuildContext context, WidgetRef ref) async {
    final confirmed = await showHollowConfirm(
      context: context,
      title: 'Leave server',
      message: 'Are you sure you want to leave "${server.name}"?\n\n'
          'You will need a new invite to rejoin this server.',
      confirmLabel: 'Leave server',
      destructive: true,
    );
    if (confirmed && context.mounted) await _leaveServer(context, ref);
  }

  Future<void> _leaveServer(BuildContext context, WidgetRef ref) async {
    try {
      await crdt_api.leaveServer(serverId: server.serverId);
      ref.read(serverSettingsOpenProvider.notifier).state = false;
      ref.read(selectedServerProvider.notifier).state = null;
      ref.read(selectedChannelProvider.notifier).state = null;
      ref.read(channelListProvider.notifier).clear();
      if (context.mounted) {
        HollowToast.show(
          context,
          'Left "${server.name}"',
          type: HollowToastType.info,
        );
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(
          context,
          'Failed to leave server: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final roleAsync = ref.watch(myRoleProvider(server.serverId));
    final isOwner = roleAsync.valueOrNull == 'owner';

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      children: [
        Container(
          padding: const EdgeInsets.all(HollowSpacing.lg),
          decoration: BoxDecoration(
            border: Border.all(color: hollow.error.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.alertTriangle,
                      size: 18, color: hollow.error),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    'Danger Zone',
                    style: HollowTypography.subheading
                        .copyWith(color: hollow.error),
                  ),
                ],
              ),
              const SizedBox(height: HollowSpacing.lg),

              if (!isOwner)
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Leave this server',
                            style: HollowTypography.body
                                .copyWith(color: hollow.textPrimary),
                          ),
                          const SizedBox(height: HollowSpacing.xxs),
                          Text(
                            'You will need a new invite to rejoin.',
                            style: HollowTypography.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    HollowButton.danger(
                      onPressed: () => _confirmLeave(context, ref),
                      icon: const Icon(LucideIcons.logOut),
                      child: const Text('Leave server'),
                    ),
                  ],
                ),

              if (isOwner)
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Delete this server',
                            style: HollowTypography.body
                                .copyWith(color: hollow.textPrimary),
                          ),
                          const SizedBox(height: HollowSpacing.xxs),
                          Text(
                            'Once deleted, all data is permanently removed.',
                            style: HollowTypography.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    HollowButton.danger(
                      onPressed: () => _confirmDelete(context, ref),
                      icon: const Icon(LucideIcons.trash2),
                      child: const Text('Delete server'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_file_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A running recovery pool: how many of the server's vault files are back, who
/// is helping, and what came back.
class RecoveryPoolDashboard extends ConsumerWidget {
  const RecoveryPoolDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final pool = ref.watch(recoveryPoolProvider);

    if (pool == null) {
      return const HollowEmptyState(title: 'No recovery pool is running');
    }

    // Local vault file data stands in until the pool status arrives.
    final localStatus = ref.watch(vaultFileStatusProvider(pool.serverId));
    var totalFiles = pool.totalFiles;
    var reconstructable = pool.reconstructable;
    var partial = pool.partial;
    var noShards = pool.noShards;
    if (totalFiles == 0 && localStatus.hasValue) {
      final files = localStatus.value!;
      totalFiles = files.length;
      reconstructable = files.where((f) => f.isReconstructable).length;
      partial = files
          .where((f) => !f.isReconstructable && f.localShardCount > 0)
          .length;
      noShards = files.where((f) => f.localShardCount == 0).length;
    }
    final serverName =
        ref.watch(serverListProvider)[pool.serverId]?.name ?? 'this server';
    final links = ref.watch(deviceLinkProvider);
    final profiles = ref.watch(profileProvider);

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        Row(
          children: [
            Expanded(
              child: HollowSectionHeader(
                'Recovery pool',
                subtitle: pool.isActive
                    ? 'Gathering shards for $serverName'
                    : 'Stopped',
              ),
            ),
            if (pool.isActive && pool.isInitiator)
              HollowButton.outline(
                danger: true,
                compact: true,
                onPressed: () => _stop(context, ref, pool.serverId,
                    initiator: true),
                child: const Text('Stop the pool'),
              )
            else if (pool.isActive)
              HollowButton.ghost(
                compact: true,
                onPressed: () => _stop(context, ref, pool.serverId,
                    initiator: false),
                child: const Text('Leave the pool'),
              ),
          ],
        ),
        if (pool.inviteLink.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  pool.inviteLink,
                  style: HollowTypography.monoSmall
                      .copyWith(color: hollow.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowIconButton(
                icon: LucideIcons.copy,
                label: 'Copy the pool invite link',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: pool.inviteLink));
                  HollowToast.show(context, 'Link copied',
                      type: HollowToastType.success);
                },
              ),
            ],
          ),
        ],
        const SizedBox(height: HollowSpacing.xl),
        // Wraps rather than overflows on a phone at a large text size.
        Wrap(
          spacing: HollowSpacing.xl,
          runSpacing: HollowSpacing.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox.square(
              dimension: 96,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator( // design-ignore: a gauge, not a spinner
                    value: totalFiles > 0 ? reconstructable / totalFiles : 0,
                    strokeWidth: 6,
                    backgroundColor: hollow.border,
                    valueColor: AlwaysStoppedAnimation(hollow.success),
                  ),
                  Center(
                    child: Text(
                      '$reconstructable of $totalFiles',
                      style: HollowTypography.label.copyWith(
                        color: hollow.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _Stat(value: reconstructable, label: 'Recovered', tone: hollow.success),
            _Stat(value: partial, label: 'Partly here', tone: hollow.warning),
            _Stat(value: noShards, label: 'Missing', tone: hollow.textSecondary),
          ],
        ),
        const SizedBox(height: HollowSpacing.xl),
        HollowSectionHeader('Helping',
            dense: true, count: '${pool.memberPeerIds.length}'),
        if (pool.memberPeerIds.isEmpty)
          const HollowEmptyState(
            dense: true,
            title: 'Waiting for someone to join',
            description: 'Send the invite link to another member.',
          )
        else
          for (final peerId in pool.memberPeerIds)
            HollowListRow(
              leading: HollowAvatar(
                  peerId: links.identityOf(peerId), size: 24),
              title: displayNameFor(profiles, links.identityOf(peerId)),
            ),
        if (pool.recoveredFiles.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.xl),
          HollowSectionHeader('Recovered files',
              dense: true, count: '${pool.recoveredFiles.length}'),
          for (final file in pool.recoveredFiles)
            HollowListRow(
              leading: Icon(LucideIcons.checkCircle,
                  size: 20, color: hollow.success),
              title: file.diskPath.isNotEmpty
                  ? file.diskPath.split(RegExp(r'[\\/]')).last
                  : file.contentId,
            ),
        ],
      ],
    );
  }

  Future<void> _stop(BuildContext context, WidgetRef ref, String serverId,
      {required bool initiator}) async {
    final pool = ref.read(recoveryPoolProvider.notifier);
    if (initiator) {
      final stopped = await showHollowConfirm(
        context: context,
        title: 'Stop the recovery pool?',
        message: 'Everyone helping is disconnected from it. Files already '
            'recovered stay on your device.',
        confirmLabel: 'Stop the pool',
        destructive: true,
        onConfirm: () => crdt_api.stopRecoveryPool(serverId: serverId),
      );
      if (!stopped) return;
      pool.clear();
      if (context.mounted) {
        HollowToast.show(context, 'Recovery pool stopped',
            type: HollowToastType.info);
      }
      return;
    }
    try {
      await crdt_api.stopRecoveryPool(serverId: serverId);
      pool.clear();
      if (context.mounted) {
        HollowToast.show(context, 'You left the pool',
            type: HollowToastType.info);
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(
          context,
          friendlyError(e,
              fallback: "Couldn't leave the pool. Try again."),
          type: HollowToastType.error,
        );
      }
    }
  }
}

/// One figure with its word underneath, the figure in its status colour.
class _Stat extends StatelessWidget {
  final int value;
  final String label;
  final Color tone;

  const _Stat({required this.value, required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: HollowTypography.heading.copyWith(
            color: tone,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(label,
            style: HollowTypography.caption
                .copyWith(color: hollow.textSecondary)),
      ],
    );
  }
}

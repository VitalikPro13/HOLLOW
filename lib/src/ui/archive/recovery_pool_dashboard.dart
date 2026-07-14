import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/core/providers/vault_file_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Dashboard for an active recovery pool. Shows progress, members, and actions.
class RecoveryPoolDashboard extends ConsumerWidget {
  const RecoveryPoolDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final pool = ref.watch(recoveryPoolProvider);

    if (pool == null) {
      return Center(
        child: Text(
          'No active recovery pool',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
      );
    }

    // Use local vault file data as fallback when pool status hasn't arrived yet.
    final localStatus = ref.watch(vaultFileStatusProvider(pool.serverId));
    int totalFiles = pool.totalFiles;
    int reconstructable = pool.reconstructable;
    int partial = pool.partial;
    int noShards = pool.noShards;
    if (totalFiles == 0 && localStatus.hasValue) {
      final files = localStatus.value!;
      totalFiles = files.length;
      reconstructable = files.where((f) => f.isReconstructable).length;
      partial = files.where((f) => !f.isReconstructable && f.localShardCount > 0).length;
      noShards = files.where((f) => f.localShardCount == 0).length;
    }

    return Align(
      alignment: Alignment.topLeft,
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header.
          Row(
            children: [
              StatusDot(
                color: pool.isActive ? const Color(0xFF4CAF50) : hollow.textSecondary,
                pulse: pool.isActive,
                size: 10,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  'Recovery Pool',
                  style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 18,
                  ),
                ),
              ),
              if (pool.isInitiator && pool.isActive)
                HollowButton.danger(
                  onPressed: () => _stopPool(context, ref, pool.serverId),
                  compact: true,
                  icon: const Icon(LucideIcons.square, size: 12),
                  child: const Text('Stop Pool'),
                ),
              if (!pool.isInitiator && pool.isActive)
                HollowButton.ghost(
                  onPressed: () => _leavePool(context, ref, pool.serverId),
                  compact: true,
                  icon: const Icon(LucideIcons.logOut, size: 12),
                  child: const Text('Leave Pool'),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            pool.isActive ? 'Active — exchanging shards' : 'Pool stopped',
            style: HollowTypography.caption.copyWith(
              color: pool.isActive ? const Color(0xFF4CAF50) : hollow.textSecondary,
              fontSize: 12,
            ),
          ),

          // Invite link (if initiator and link available).
          if (pool.inviteLink.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.md),
            Container(
              padding: const EdgeInsets.all(HollowSpacing.md),
              decoration: BoxDecoration(
                color: hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                border: Border.all(color: hollow.border),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.link, size: 14, color: hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      pool.inviteLink,
                      style: HollowTypography.mono.copyWith(
                        color: hollow.accent,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowPressable(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: pool.inviteLink));
                      HollowToast.show(context, 'Link copied', type: HollowToastType.success);
                    },
                    semanticLabel: 'Copy',
                    borderRadius: BorderRadius.circular(4),
                    padding: const EdgeInsets.all(6),
                    child: Icon(LucideIcons.copy, size: 14, color: hollow.textSecondary),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: HollowSpacing.lg),

          // Progress section.
          _buildProgressRing(hollow, totalFiles, reconstructable),
          const SizedBox(height: HollowSpacing.lg),

          // Stats row.
          Row(
            children: [
              _StatCard(
                label: 'Recovered',
                value: '$reconstructable',
                color: const Color(0xFF4CAF50),
                hollow: hollow,
              ),
              const SizedBox(width: HollowSpacing.sm),
              _StatCard(
                label: 'Partial',
                value: '$partial',
                color: const Color(0xFFFFA726),
                hollow: hollow,
              ),
              const SizedBox(width: HollowSpacing.sm),
              _StatCard(
                label: 'Missing',
                value: '$noShards',
                color: hollow.textSecondary,
                hollow: hollow,
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),

          // Members section.
          Text(
            'MEMBERS (${pool.memberPeerIds.length})',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          if (pool.memberPeerIds.isEmpty)
            Text(
              'Waiting for members to join...',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
            )
          else
            for (final peerId in pool.memberPeerIds)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.surface,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    border: Border.all(color: hollow.border),
                  ),
                  child: Row(
                    children: [
                      Icon(LucideIcons.user, size: 14, color: hollow.textSecondary),
                      const SizedBox(width: HollowSpacing.sm),
                      Expanded(
                        child: Text(
                          peerId.length > 12
                              ? '${peerId.substring(0, 6)}...${peerId.substring(peerId.length - 6)}'
                              : peerId,
                          style: HollowTypography.mono.copyWith(
                            color: hollow.textPrimary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const StatusDot(
                        color: Color(0xFF4CAF50),
                        size: 6,
                      ),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: HollowSpacing.lg),

          // Recovered files section.
          if (pool.recoveredFiles.isNotEmpty) ...[
            Text(
              'RECOVERED FILES (${pool.recoveredFiles.length})',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            for (final file in pool.recoveredFiles)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4CAF50).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    border: Border.all(
                      color: const Color(0xFF4CAF50).withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(LucideIcons.checkCircle, size: 14, color: Color(0xFF4CAF50)),
                      const SizedBox(width: HollowSpacing.sm),
                      Expanded(
                        child: Text(
                          file.contentId.length > 16
                              ? '${file.contentId.substring(0, 8)}...${file.contentId.substring(file.contentId.length - 8)}'
                              : file.contentId,
                          style: HollowTypography.mono.copyWith(
                            color: hollow.textPrimary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    ),
    );
  }

  Widget _buildProgressRing(HollowTheme hollow, int total, int recovered) {
    final progress = total > 0 ? recovered / total : 0.0;

    return Center(
      child: SizedBox(
        width: 120,
        height: 120,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CircularProgressIndicator(
              value: progress,
              strokeWidth: 8,
              backgroundColor: hollow.border,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF4CAF50)),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$recovered/$total',
                    style: HollowTypography.heading.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 22,
                    ),
                  ),
                  Text(
                    'files',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _stopPool(BuildContext context, WidgetRef ref, String serverId) async {
    try {
      await crdt_api.stopRecoveryPool(serverId: serverId);
      ref.read(recoveryPoolProvider.notifier).clear();
      if (context.mounted) {
        HollowToast.show(
          context,
          'Recovery pool stopped',
          type: HollowToastType.info,
        );
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(
          context,
          'Failed to stop pool: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  Future<void> _leavePool(BuildContext context, WidgetRef ref, String serverId) async {
    try {
      await crdt_api.stopRecoveryPool(serverId: serverId);
      ref.read(recoveryPoolProvider.notifier).clear();
      if (context.mounted) {
        HollowToast.show(
          context,
          'Left recovery pool',
          type: HollowToastType.info,
        );
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(
          context,
          'Failed to leave pool: $e',
          type: HollowToastType.error,
        );
      }
    }
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final HollowTheme hollow;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(HollowSpacing.md),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: HollowTypography.heading.copyWith(
                color: color,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: HollowSpacing.xxs),
            Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

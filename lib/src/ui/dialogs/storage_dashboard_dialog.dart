import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/core/providers/vault_status_provider.dart';
import 'package:haven/src/rust/api/crdt.dart' as crdt_api;
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_card.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

void showStorageDashboardDialog(BuildContext context, String serverId) {
  showHavenDialog(
    context: context,
    builder: (ctx) => ProviderScope(
      child: _StorageDashboardContent(serverId: serverId),
    ),
  );
}

class _StorageDashboardContent extends ConsumerStatefulWidget {
  final String serverId;
  const _StorageDashboardContent({required this.serverId});

  @override
  ConsumerState<_StorageDashboardContent> createState() =>
      _StorageDashboardContentState();
}

class _StorageDashboardContentState
    extends ConsumerState<_StorageDashboardContent> {
  crdt_api.StorageStatsFfi? _stats;
  String _retentionFiles = 'permanent';
  String _retentionVoice = '90d';
  int _diskFreeBytes = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final stats =
          await crdt_api.getStorageStats(serverId: widget.serverId);
      final retFiles = await crdt_api.getServerSetting(
          serverId: widget.serverId, key: 'retention_files');
      final retVoice = await crdt_api.getServerSetting(
          serverId: widget.serverId, key: 'retention_voice');

      int diskFree = 0;
      try {
        if (Platform.isWindows) {
          final result = await Process.run('powershell', [
            '-Command',
            r"(Get-PSDrive C).Free",
          ]);
          final output = result.stdout.toString().trim();
          diskFree = int.tryParse(output) ?? 0;
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _stats = stats;
          _retentionFiles = retFiles.isNotEmpty ? retFiles : 'permanent';
          _retentionVoice = retVoice.isNotEmpty ? retVoice : '90d';
          _diskFreeBytes = diskFree;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _formatBytes(BigInt bytes) {
    final b = bytes.toDouble();
    if (b < 1024) return '${b.toInt()} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  String _formatBytesInt(int bytes) =>
      _formatBytes(BigInt.from(bytes));

  String _formatRetention(String policy) {
    if (policy.isEmpty || policy == 'permanent') return 'Permanent';
    return '${policy.replaceAll("d", "")} days';
  }

  String _vaultModeLabel(int memberCount) {
    if (memberCount < 6) return 'Full Replication';
    if (memberCount <= 8) return 'Erasure Coding (k=3/m=2)';
    if (memberCount <= 15) return 'Erasure Coding (k=5/m=3)';
    if (memberCount <= 30) return 'Erasure Coding (k=8/m=4)';
    if (memberCount <= 60) return 'Erasure Coding (k=10/m=5)';
    if (memberCount <= 150) return 'Erasure Coding (k=12/m=6)';
    if (memberCount <= 500) return 'Erasure Coding (k=16/m=8)';
    return 'Erasure Coding (k=20/m=10)';
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final memberCount = membersAsync.valueOrNull?.length ?? 0;
    final vaultStatus = ref.watch(
      vaultStatusProvider.select((s) => s[widget.serverId]),
    );

    return HavenDialog(
      title: '',
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with title + close button
            Row(
              children: [
                Icon(LucideIcons.hardDrive, size: 18, color: haven.accent),
                const SizedBox(width: HavenSpacing.sm),
                Text(
                  'Storage Dashboard',
                  style: HavenTypography.heading.copyWith(
                    color: haven.textPrimary,
                  ),
                ),
                const Spacer(),
                HavenPressable(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(
                    LucideIcons.x,
                    size: 16,
                    color: haven.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HavenSpacing.lg),

            if (_loading)
              const SizedBox(
                height: 150,
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              // Top row: Server Storage | Your Storage
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildSection(
                      haven,
                      'Server Storage',
                      LucideIcons.server,
                      _buildServerOverview(haven, memberCount),
                    ),
                  ),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: _buildSection(
                      haven,
                      'Your Storage',
                      LucideIcons.user,
                      _buildYourStorage(haven),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: HavenSpacing.md),

              // Bottom row: Retention Policy | Vault Health
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildSection(
                      haven,
                      'Retention Policy',
                      LucideIcons.clock,
                      _buildRetentionPolicy(haven),
                    ),
                  ),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: _buildSection(
                      haven,
                      'Vault Health',
                      LucideIcons.shield,
                      _buildVaultHealth(haven, vaultStatus, memberCount),
                    ),
                  ),
                ],
              ),

              // Member Pledges (6+ only) — full width below
              if (memberCount >= 6) ...[
                const SizedBox(height: HavenSpacing.md),
                _buildSection(
                  haven,
                  'Member Pledges',
                  LucideIcons.users,
                  _buildMemberPledges(haven, memberCount),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    HavenTheme haven,
    String title,
    IconData icon,
    Widget content,
  ) {
    return HavenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: haven.accent),
              const SizedBox(width: HavenSpacing.sm),
              Text(
                title,
                style: HavenTypography.caption.copyWith(
                  color: haven.accent,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: HavenSpacing.md),
          content,
        ],
      ),
    );
  }

  Widget _buildServerOverview(HavenTheme haven, int memberCount) {
    final stats = _stats;
    if (stats == null) return const SizedBox.shrink();

    final totalPledged = stats.totalPledgedBytes.toDouble();
    final totalUsed = stats.totalUsedBytes.toDouble();
    final fraction = totalPledged > 0 ? totalUsed / totalPledged : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _vaultModeLabel(memberCount),
          style: HavenTypography.body.copyWith(
            color: haven.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        _storageBar(fraction, haven.accent, haven),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          '${_formatBytes(stats.totalUsedBytes)} / ${_formatBytes(stats.totalPledgedBytes)}',
          style: HavenTypography.caption.copyWith(color: haven.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          '$memberCount members',
          style: HavenTypography.caption.copyWith(color: haven.textSecondary),
        ),
      ],
    );
  }

  Widget _buildYourStorage(HavenTheme haven) {
    final stats = _stats;
    if (stats == null) return const SizedBox.shrink();

    final myPledge = stats.myPledgeBytes.toDouble();
    final myUsed = stats.myUsedBytes.toDouble();
    final fraction = myPledge > 0 ? myUsed / myPledge : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pledge: ${_formatBytes(stats.myPledgeBytes)}',
          style: HavenTypography.body.copyWith(
            color: haven.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: HavenSpacing.sm),
        _storageBar(fraction, haven.accent, haven),
        const SizedBox(height: HavenSpacing.xs),
        Text(
          '${_formatBytes(stats.myUsedBytes)} used',
          style: HavenTypography.caption.copyWith(color: haven.textSecondary),
        ),
        if (_diskFreeBytes > 0) ...[
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(
                _diskFreeBytes < 1024 * 1024 * 1024
                    ? LucideIcons.alertTriangle
                    : LucideIcons.hardDrive,
                size: 11,
                color: _diskFreeBytes < 1024 * 1024 * 1024
                    ? haven.error
                    : haven.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '${_formatBytesInt(_diskFreeBytes)} free',
                style: HavenTypography.caption.copyWith(
                  color: _diskFreeBytes < 1024 * 1024 * 1024
                      ? haven.error
                      : haven.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMemberPledges(HavenTheme haven, int memberCount) {
    final stats = _stats;
    if (stats == null) return const SizedBox.shrink();

    final avgPledge = memberCount > 0
        ? stats.totalPledgedBytes ~/ BigInt.from(memberCount)
        : BigInt.zero;

    return Row(
      children: [
        Expanded(
          child: Text(
            '$memberCount members contributing',
            style: HavenTypography.body.copyWith(color: haven.textPrimary),
          ),
        ),
        Text(
          'Avg: ${_formatBytes(avgPledge)} each',
          style: HavenTypography.caption.copyWith(color: haven.textSecondary),
        ),
      ],
    );
  }

  Widget _buildRetentionPolicy(HavenTheme haven) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _retentionRow(haven, 'Files', _retentionFiles),
        const SizedBox(height: HavenSpacing.xs),
        _retentionRow(haven, 'Voice', _retentionVoice),
        const SizedBox(height: HavenSpacing.sm),
        Text(
          'Forward-only: changes affect new uploads only.',
          style: HavenTypography.caption.copyWith(
            color: haven.textSecondary,
            fontStyle: FontStyle.italic,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _retentionRow(HavenTheme haven, String label, String policy) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            '$label:',
            style: HavenTypography.body.copyWith(color: haven.textSecondary),
          ),
        ),
        Text(
          _formatRetention(policy),
          style: HavenTypography.body.copyWith(
            color: haven.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildVaultHealth(
    HavenTheme haven,
    VaultServerStatus? status,
    int memberCount,
  ) {
    final health = status?.computeHealth() ?? VaultHealth.healthy;
    final message = status?.healthMessage ?? (memberCount < 6
        ? 'All files synced'
        : 'No vault activity yet');
    final color = switch (health) {
      VaultHealth.healthy => haven.success,
      VaultHealth.degraded => haven.warning,
      VaultHealth.critical => haven.error,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusDot(
              color: color,
              size: 8,
              pulse: health != VaultHealth.healthy,
            ),
            const SizedBox(width: HavenSpacing.sm),
            Expanded(
              child: Text(
                message,
                style: HavenTypography.body.copyWith(color: haven.textPrimary),
              ),
            ),
          ],
        ),
        if (memberCount < 6) ...[
          const SizedBox(height: HavenSpacing.sm),
          Text(
            'Every member stores all files.',
            style: HavenTypography.caption.copyWith(
              color: haven.textSecondary,
              fontSize: 10,
            ),
          ),
        ],
      ],
    );
  }

  Widget _storageBar(double fraction, Color color, HavenTheme haven) {
    final barColor = fraction > 0.9
        ? haven.error
        : fraction > 0.7
            ? haven.warning
            : color;

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Stack(
          children: [
            Container(color: haven.border),
            FractionallySizedBox(
              widthFactor: fraction.clamp(0.0, 1.0),
              child: Container(
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

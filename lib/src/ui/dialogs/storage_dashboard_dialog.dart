import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_card.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons/lucide_icons.dart';

void showStorageDashboardDialog(BuildContext context, String serverId) {
  showHollowDialog(
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
  // Static cache — persists across dialog open/close so it shows instantly on reopen.
  static final Map<String, crdt_api.StorageStatsFfi> _statsCache = {};
  static final Map<String, String> _retentionFilesCache = {};
  static final Map<String, String> _retentionMessagesCache = {};
  static int _diskFreeBytesCache = 0;

  crdt_api.StorageStatsFfi? _stats;
  String _retentionFiles = '365d';
  String _retentionMessages = '365d';
  int _diskFreeBytes = 0;

  @override
  void initState() {
    super.initState();
    // Load cached values immediately so UI appears instantly.
    _stats = _statsCache[widget.serverId];
    _retentionFiles = _retentionFilesCache[widget.serverId] ?? '365d';
    _retentionMessages = _retentionMessagesCache[widget.serverId] ?? '365d';
    _diskFreeBytes = _diskFreeBytesCache;
    // Refresh in background — setState triggers smooth animation.
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        crdt_api.getStorageStats(serverId: widget.serverId),
        crdt_api.getServerSetting(serverId: widget.serverId, key: 'retention_files'),
        crdt_api.getServerSetting(serverId: widget.serverId, key: 'retention_messages'),
        _getDiskFreeBytes(),
      ]);

      final stats = results[0] as crdt_api.StorageStatsFfi;
      final retFiles = results[1] as String;
      final retMessages = results[2] as String;
      final diskFree = results[3] as int;

      // Update static cache for next open.
      _statsCache[widget.serverId] = stats;
      _retentionFilesCache[widget.serverId] = retFiles.isNotEmpty ? retFiles : '365d';
      _retentionMessagesCache[widget.serverId] = retMessages.isNotEmpty ? retMessages : '365d';
      _diskFreeBytesCache = diskFree;

      if (mounted) {
        setState(() {
          _stats = stats;
          _retentionFiles = _retentionFilesCache[widget.serverId]!;
          _retentionMessages = _retentionMessagesCache[widget.serverId]!;
          _diskFreeBytes = diskFree;
        });
      }
    } catch (_) {}
  }

  Future<int> _getDiskFreeBytes() async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell', [
          '-Command',
          r"(Get-PSDrive C).Free",
        ]);
        return int.tryParse(result.stdout.toString().trim()) ?? 0;
      }
    } catch (_) {}
    return 0;
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

  /// Returns (k, m) for the current member count.
  /// Used to compute the redundancy overhead factor: (k+m)/k.
  (int, int) _vaultParams(int memberCount) {
    if (memberCount <= 8) return (3, 2);
    if (memberCount <= 15) return (5, 3);
    if (memberCount <= 30) return (8, 4);
    if (memberCount <= 60) return (10, 5);
    if (memberCount <= 150) return (12, 6);
    if (memberCount <= 500) return (16, 8);
    return (20, 10);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final membersAsync = ref.watch(serverMembersProvider(widget.serverId));
    final memberCount = membersAsync.valueOrNull?.length ?? 0;
    final vaultStatus = ref.watch(
      vaultStatusProvider.select((s) => s[widget.serverId]),
    );

    return HollowDialog(
      title: '',
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with title + close button
            Row(
              children: [
                Icon(LucideIcons.hardDrive, size: 18, color: hollow.accent),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  'Storage Dashboard',
                  style: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                  ),
                ),
                const Spacer(),
                HollowPressable(
                  onTap: () => Navigator.of(context).pop(),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(
                    LucideIcons.x,
                    size: 16,
                    color: hollow.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.lg),

            ...[
              // Server Storage — full width when <6 members, side-by-side when 6+
              if (memberCount < 6)
                _buildSection(
                  hollow,
                  'Server Storage',
                  LucideIcons.server,
                  _buildServerOverview(hollow, memberCount),
                )
              else
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _buildSection(
                          hollow,
                          'Server Storage',
                          LucideIcons.server,
                          _buildServerOverview(hollow, memberCount),
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.md),
                      Expanded(
                        child: _buildSection(
                          hollow,
                          'Your Storage',
                          LucideIcons.user,
                          _buildYourStorage(hollow),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: HollowSpacing.md),

              // Bottom row: Retention Policy | Vault Health — equal height
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildSection(
                        hollow,
                        'Retention Policy',
                        LucideIcons.clock,
                        _buildRetentionPolicy(hollow),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.md),
                    Expanded(
                      child: _buildSection(
                        hollow,
                        'Vault Health',
                        LucideIcons.shield,
                        _buildVaultHealth(hollow, vaultStatus, memberCount),
                      ),
                    ),
                  ],
                ),
              ),

              // Member Pledges (6+ only) — full width below
              if (memberCount >= 6) ...[
                const SizedBox(height: HollowSpacing.md),
                _buildSection(
                  hollow,
                  'Member Pledges',
                  LucideIcons.users,
                  _buildMemberPledges(hollow, memberCount),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    HollowTheme hollow,
    String title,
    IconData icon,
    Widget content,
  ) {
    return HollowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                title,
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          content,
        ],
      ),
    );
  }

  Widget _buildServerOverview(HollowTheme hollow, int memberCount) {
    final stats = _stats;
    final totalUsed = stats?.totalUsedBytes.toDouble() ?? 0;

    if (memberCount < 6) {
      // Full replication — bar shows server data vs disk capacity.
      // Total disk = used + free. Bar fill = server data / total disk.
      final diskTotal = totalUsed + _diskFreeBytes.toDouble();
      final fraction = diskTotal > 0 ? totalUsed / diskTotal : 0.0;
      final diskFreeColor = _diskFreeBytes < 1024 * 1024 * 1024
          ? hollow.error
          : hollow.textSecondary;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _vaultModeLabel(memberCount),
            style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          _storageBar(fraction, hollow.accent, hollow),
          const SizedBox(height: HollowSpacing.xs),
          Row(
            children: [
              Text(
                _formatBytes(stats?.totalUsedBytes ?? BigInt.zero),
                style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
              ),
              const Spacer(),
              if (_diskFreeBytes > 0) ...[
                Icon(
                  _diskFreeBytes < 1024 * 1024 * 1024
                      ? LucideIcons.alertTriangle
                      : LucideIcons.hardDrive,
                  size: 11,
                  color: diskFreeColor,
                ),
                const SizedBox(width: 4),
                Text(
                  '${_formatBytesInt(_diskFreeBytes)} free',
                  style: HollowTypography.caption.copyWith(color: diskFreeColor),
                ),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$memberCount members',
            style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
          ),
        ],
      );
    }

    // Erasure coding (6+) — bar shows server data vs effective usable capacity.
    // Effective capacity = total pledged × k / (k + m) to account for redundancy overhead.
    final totalPledged = stats?.totalPledgedBytes.toDouble() ?? 0;
    final (k, m) = _vaultParams(memberCount);
    final redundancyFactor = k > 0 ? (k + m) / k : 1.0;
    final effectiveCapacity = totalPledged / redundancyFactor;
    final fraction = effectiveCapacity > 0 ? totalUsed / effectiveCapacity : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _vaultModeLabel(memberCount),
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _storageBar(fraction.clamp(0.0, 1.0), hollow.accent, hollow),
        const SizedBox(height: HollowSpacing.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_formatBytes(stats?.totalUsedBytes ?? BigInt.zero)} / ${_formatBytes(BigInt.from(effectiveCapacity.toInt()))}',
              style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
            ),
            Text(
              '${redundancyFactor.toStringAsFixed(1)}x overhead',
              style: HollowTypography.caption.copyWith(color: hollow.textSecondary.withValues(alpha: 0.6), fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '$memberCount members · ${_formatBytes(stats?.totalPledgedBytes ?? BigInt.zero)} raw capacity',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }

  Future<void> _editPledge(HollowTheme hollow) async {
    final currentMb = (_stats?.myPledgeBytes.toDouble() ?? 512 * 1024 * 1024) / (1024 * 1024);
    final controller = TextEditingController(text: currentMb.toInt().toString());

    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: hollow.elevated,
        title: Text('Set Storage Pledge', style: TextStyle(color: hollow.textPrimary, fontSize: 16)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          style: TextStyle(color: hollow.textPrimary),
          decoration: InputDecoration(
            suffixText: 'MB',
            suffixStyle: TextStyle(color: hollow.textSecondary),
            hintText: 'Min 512',
            hintStyle: TextStyle(color: hollow.textSecondary.withValues(alpha: 0.4)),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: hollow.border)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: hollow.accent)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: hollow.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              final mb = int.tryParse(controller.text);
              if (mb != null && mb >= 512) Navigator.pop(ctx, mb);
            },
            child: Text('Save', style: TextStyle(color: hollow.accent)),
          ),
        ],
      ),
    );

    if (result != null) {
      try {
        await crdt_api.setStoragePledge(
          serverId: widget.serverId,
          pledgeBytes: BigInt.from(result) * BigInt.from(1024 * 1024),
        );
        _loadData(); // Refresh stats.
      } catch (e) {
        debugPrint('[HOLLOW] Failed to set pledge: $e');
      }
    }
  }

  Widget _buildYourStorage(HollowTheme hollow) {
    final stats = _stats;
    if (stats == null) return const SizedBox.shrink();

    final myPledge = stats.myPledgeBytes.toDouble();
    final myUsed = stats.myUsedBytes.toDouble();
    final fraction = myPledge > 0 ? myUsed / myPledge : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowPressable(
          onTap: () => _editPledge(hollow),
          borderRadius: BorderRadius.circular(4),
          padding: EdgeInsets.zero,
          child: Row(
            children: [
              Text(
                'Pledge: ${_formatBytes(stats.myPledgeBytes)}',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Icon(LucideIcons.pencil, size: 11, color: hollow.textSecondary),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _storageBar(fraction, hollow.accent, hollow),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          '${_formatBytes(stats.myUsedBytes)} used',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
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
                    ? hollow.error
                    : hollow.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                '${_formatBytesInt(_diskFreeBytes)} free',
                style: HollowTypography.caption.copyWith(
                  color: _diskFreeBytes < 1024 * 1024 * 1024
                      ? hollow.error
                      : hollow.textSecondary,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildMemberPledges(HollowTheme hollow, int memberCount) {
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
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
          ),
        ),
        Text(
          'Avg: ${_formatBytes(avgPledge)} each',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }

  static const _retentionOptions = [
    ('permanent', 'Permanent'),
    ('30d', '30 days'),
    ('90d', '90 days'),
    ('180d', '180 days'),
    ('365d', '365 days'),
  ];

  Future<void> _editRetention(HollowTheme hollow, String key, String currentValue) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: hollow.elevated,
        title: Text(
          key == 'retention_files' ? 'File Retention' : key == 'retention_messages' ? 'Message Retention' : 'Voice Retention',
          style: TextStyle(color: hollow.textPrimary, fontSize: 16),
        ),
        children: [
          for (final (value, label) in _retentionOptions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, value),
              child: Row(
                children: [
                  if (value == currentValue || (currentValue == '' && value == 'permanent'))
                    Icon(LucideIcons.check, size: 14, color: hollow.accent)
                  else
                    const SizedBox(width: 14),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(label, style: TextStyle(color: hollow.textPrimary)),
                ],
              ),
            ),
        ],
      ),
    );

    if (result != null && result != currentValue) {
      try {
        await crdt_api.updateServerSetting(
          serverId: widget.serverId,
          key: key,
          value: result,
        );
        // Forward-only: record when the policy was changed so only
        // messages/files created after this point are subject to pruning.
        final sinceKey = '${key}_since';
        final nowSecs = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
        await crdt_api.updateServerSetting(
          serverId: widget.serverId,
          key: sinceKey,
          value: nowSecs,
        );
        _loadData();
      } catch (e) {
        debugPrint('[HOLLOW] Failed to update retention: $e');
      }
    }
  }

  Widget _buildRetentionPolicy(HollowTheme hollow) {
    final role = ref.watch(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';
    final canEdit = role == 'owner' || role == 'admin';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _retentionRow(hollow, 'Messages', 'retention_messages', _retentionMessages, canEdit: canEdit),
        const SizedBox(height: HollowSpacing.xs),
        _retentionRow(hollow, 'Files', 'retention_files', _retentionFiles, canEdit: canEdit),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Changes affect new content only.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontStyle: FontStyle.italic,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _retentionRow(HollowTheme hollow, String label, String settingKey, String policy, {bool canEdit = true}) {
    return HollowPressable(
      onTap: canEdit ? () => _editRetention(hollow, settingKey, policy) : null,
      borderRadius: BorderRadius.circular(4),
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              '$label:',
              style: HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
          ),
          Text(
            _formatRetention(policy),
            style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (canEdit) ...[
            const SizedBox(width: HollowSpacing.xs),
            Icon(LucideIcons.pencil, size: 11, color: hollow.textSecondary),
          ],
        ],
      ),
    );
  }

  Widget _buildVaultHealth(
    HollowTheme hollow,
    VaultServerStatus? status,
    int memberCount,
  ) {
    if (memberCount < 6) {
      // Full replication mode — simple summary.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusDot(color: hollow.success, size: 8),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Full replication',
                style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Every member stores all files. Erasure coding activates at 6+ members.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 10,
            ),
          ),
        ],
      );
    }

    // Erasure coding mode — show shard health summary.
    final shardCount = status?.shardsStoredLocally ?? 0;
    final activeUploads = status?.activeUploads.values
        .where((u) => u.phase != 'complete' && u.phase != 'failed')
        .length ?? 0;
    final activeDownloads = status?.activeDownloads.length ?? 0;
    final hasFailed = status?.activeUploads.values
        .any((u) => u.phase == 'failed') ?? false;

    final color = hasFailed
        ? hollow.error
        : (activeUploads > 0 || activeDownloads > 0)
            ? hollow.warning
            : hollow.success;
    final statusText = hasFailed
        ? 'Distribution failed'
        : (activeUploads > 0 || activeDownloads > 0)
            ? '${activeUploads + activeDownloads} transfer${(activeUploads + activeDownloads) > 1 ? 's' : ''} in progress'
            : 'All shards healthy';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusDot(
              color: color,
              size: 8,
              pulse: activeUploads > 0 || activeDownloads > 0 || hasFailed,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              statusText,
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          '$shardCount shard${shardCount != 1 ? 's' : ''} stored locally',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _storageBar(double fraction, Color color, HollowTheme hollow) {
    final clamped = fraction.clamp(0.0, 1.0);
    final barColor = fraction > 0.9
        ? hollow.error
        : fraction > 0.7
            ? hollow.warning
            : color;

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Stack(
          children: [
            Container(color: hollow.border),
            TweenAnimationBuilder<double>(
              tween: Tween(end: clamped),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => FractionallySizedBox(
                widthFactor: value,
                child: Container(
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

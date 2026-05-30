import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileStorageRoute extends ConsumerStatefulWidget {
  final String serverId;
  const MobileStorageRoute({super.key, required this.serverId});

  @override
  ConsumerState<MobileStorageRoute> createState() => _MobileStorageRouteState();
}

class _MobileStorageRouteState extends ConsumerState<MobileStorageRoute> {
  crdt_api.StorageStatsFfi? _stats;
  String _retentionFiles = '365d';
  String _retentionMessages = '365d';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final results = await Future.wait([
        crdt_api.getStorageStats(serverId: widget.serverId),
        crdt_api.getServerSetting(serverId: widget.serverId, key: 'retention_files'),
        crdt_api.getServerSetting(serverId: widget.serverId, key: 'retention_messages'),
      ]);

      if (mounted) {
        setState(() {
          _stats = results[0] as crdt_api.StorageStatsFfi;
          final retFiles = results[1] as String;
          final retMessages = results[2] as String;
          _retentionFiles = retFiles.isNotEmpty ? retFiles : '365d';
          _retentionMessages = retMessages.isNotEmpty ? retMessages : '365d';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatBytes(BigInt bytes) {
    final b = bytes.toDouble();
    if (b < 1024) return '${b.toInt()} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

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
    final role = ref.watch(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';
    final canEdit = role == 'owner' || role == 'admin';

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HollowSpacing.xs, HollowSpacing.sm,
                HollowSpacing.lg, HollowSpacing.sm,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.arrow_back, color: hollow.textPrimary),
                  ),
                  Icon(LucideIcons.hardDrive, size: 18, color: hollow.accent),
                  const SizedBox(width: HollowSpacing.sm),
                  Text('Storage', style: HollowTypography.subheading.copyWith(
                    color: hollow.textPrimary, fontWeight: FontWeight.w600,
                  )),
                ],
              ),
            ),

            Expanded(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: hollow.accent))
                  : ListView(
                      padding: const EdgeInsets.all(HollowSpacing.lg),
                      children: [
                        // Server Storage
                        _SectionCard(
                          hollow: hollow,
                          icon: LucideIcons.server,
                          title: 'Server Storage',
                          child: _buildServerOverview(hollow, memberCount),
                        ),

                        const SizedBox(height: HollowSpacing.md),

                        // Your Storage (6+ members)
                        if (memberCount >= 6) ...[
                          _SectionCard(
                            hollow: hollow,
                            icon: LucideIcons.user,
                            title: 'Your Storage',
                            child: _buildYourStorage(hollow),
                          ),
                          const SizedBox(height: HollowSpacing.md),
                        ],

                        // Retention Policy
                        _SectionCard(
                          hollow: hollow,
                          icon: LucideIcons.clock,
                          title: 'Retention Policy',
                          child: _buildRetention(hollow, canEdit),
                        ),

                        const SizedBox(height: HollowSpacing.md),

                        // Vault Health
                        _SectionCard(
                          hollow: hollow,
                          icon: LucideIcons.shield,
                          title: 'Vault Health',
                          child: _buildVaultHealth(hollow, vaultStatus, memberCount),
                        ),

                        // Member Pledges (6+ members)
                        if (memberCount >= 6) ...[
                          const SizedBox(height: HollowSpacing.md),
                          _SectionCard(
                            hollow: hollow,
                            icon: LucideIcons.users,
                            title: 'Member Pledges',
                            child: _buildMemberPledges(hollow, memberCount),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServerOverview(HollowTheme hollow, int memberCount) {
    final stats = _stats;
    final totalUsed = stats?.totalUsedBytes.toDouble() ?? 0;

    if (memberCount < 6) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_vaultModeLabel(memberCount),
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary, fontWeight: FontWeight.w500,
              )),
          const SizedBox(height: HollowSpacing.sm),
          _storageBar(0.0, hollow.accent, hollow),
          const SizedBox(height: HollowSpacing.xs),
          Text(_formatBytes(stats?.totalUsedBytes ?? BigInt.zero),
              style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
          const SizedBox(height: 2),
          Text('$memberCount members',
              style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
        ],
      );
    }

    final totalPledged = stats?.totalPledgedBytes.toDouble() ?? 0;
    final (k, m) = _vaultParams(memberCount);
    final redundancyFactor = k > 0 ? (k + m) / k : 1.0;
    final effectiveCapacity = totalPledged / redundancyFactor;
    final fraction = effectiveCapacity > 0 ? totalUsed / effectiveCapacity : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_vaultModeLabel(memberCount),
            style: HollowTypography.body.copyWith(
              color: hollow.textPrimary, fontWeight: FontWeight.w500,
            )),
        const SizedBox(height: HollowSpacing.sm),
        _storageBar(fraction.clamp(0.0, 1.0), hollow.accent, hollow),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          '${_formatBytes(stats?.totalUsedBytes ?? BigInt.zero)} / ${_formatBytes(BigInt.from(effectiveCapacity.toInt()))}',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          '$memberCount members · ${redundancyFactor.toStringAsFixed(1)}x overhead',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
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
              Text('Pledge: ${_formatBytes(stats.myPledgeBytes)}',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary, fontWeight: FontWeight.w500,
                  )),
              const SizedBox(width: HollowSpacing.xs),
              Icon(LucideIcons.pencil, size: 11, color: hollow.textSecondary),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _storageBar(fraction, hollow.accent, hollow),
        const SizedBox(height: HollowSpacing.xs),
        Text('${_formatBytes(stats.myUsedBytes)} used',
            style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
      ],
    );
  }

  Future<void> _editPledge(HollowTheme hollow) async {
    final currentMb = (_stats?.myPledgeBytes.toDouble() ?? 512 * 1024 * 1024) / (1024 * 1024);
    final controller = TextEditingController(text: currentMb.toInt().toString());

    final result = await showHollowDialog<int>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Set Storage Pledge',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowTextField(
              controller: controller,
              hintText: 'Min 512 MB',
              autofocus: true,
            ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () {
              final mb = int.tryParse(controller.text);
              if (mb != null && mb >= 512) Navigator.pop(ctx, mb);
            },
            child: const Text('Save'),
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
        _loadData();
      } catch (e) {
        if (mounted) {
          HollowToast.show(context, 'Failed to set pledge',
              type: HollowToastType.error);
        }
      }
    }
  }

  Widget _buildRetention(HollowTheme hollow, bool canEdit) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _retentionRow(hollow, 'Messages', 'retention_messages', _retentionMessages, canEdit: canEdit),
        const SizedBox(height: HollowSpacing.xs),
        _retentionRow(hollow, 'Files', 'retention_files', _retentionFiles, canEdit: canEdit),
        const SizedBox(height: HollowSpacing.sm),
        Text('Changes affect new content only.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontStyle: FontStyle.italic, fontSize: 10,
            )),
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

  Widget _retentionRow(HollowTheme hollow, String label, String settingKey,
      String policy, {bool canEdit = true}) {
    return HollowPressable(
      onTap: canEdit ? () => _editRetention(hollow, settingKey, policy) : null,
      borderRadius: BorderRadius.circular(4),
      padding: EdgeInsets.zero,
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text('$label:', style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
            )),
          ),
          Text(_formatRetention(policy), style: HollowTypography.body.copyWith(
            color: hollow.textPrimary, fontWeight: FontWeight.w500,
          )),
          if (canEdit) ...[
            const SizedBox(width: HollowSpacing.xs),
            Icon(LucideIcons.pencil, size: 11, color: hollow.textSecondary),
          ],
        ],
      ),
    );
  }

  Future<void> _editRetention(HollowTheme hollow, String key, String currentValue) async {
    final result = await showHollowDialog<String>(
      context: context,
      builder: (ctx) {
        return HollowDialog(
          title: key == 'retention_files' ? 'File Retention' : 'Message Retention',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (value, label) in _retentionOptions)
                HollowPressable(
                  onTap: () => Navigator.pop(ctx, value),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md, vertical: HollowSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        (value == currentValue || (currentValue == '' && value == 'permanent'))
                            ? LucideIcons.circleCheck
                            : LucideIcons.circle,
                        size: 16,
                        color: (value == currentValue || (currentValue == '' && value == 'permanent'))
                            ? hollow.accent
                            : hollow.textSecondary,
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Text(label, style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                      )),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );

    if (result != null && result != currentValue) {
      try {
        await crdt_api.updateServerSetting(
          serverId: widget.serverId, key: key, value: result,
        );
        final sinceKey = '${key}_since';
        final nowSecs = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
        await crdt_api.updateServerSetting(
          serverId: widget.serverId, key: sinceKey, value: nowSecs,
        );
        _loadData();
      } catch (e) {
        if (mounted) {
          HollowToast.show(context, 'Failed to update', type: HollowToastType.error);
        }
      }
    }
  }

  Widget _buildVaultHealth(HollowTheme hollow, VaultServerStatus? status, int memberCount) {
    if (memberCount < 6) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            StatusDot(color: hollow.success, size: 8),
            const SizedBox(width: HollowSpacing.sm),
            Text('Full replication', style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
            )),
          ]),
          const SizedBox(height: HollowSpacing.xs),
          Text('Every member stores all files. Erasure coding activates at 6+ members.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary, fontSize: 10,
              )),
        ],
      );
    }

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
        Row(children: [
          StatusDot(
            color: color, size: 8,
            pulse: activeUploads > 0 || activeDownloads > 0 || hasFailed,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Text(statusText, style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
          )),
        ]),
        const SizedBox(height: HollowSpacing.xs),
        Text('$shardCount shard${shardCount != 1 ? 's' : ''} stored locally',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 10,
            )),
      ],
    );
  }

  Widget _buildMemberPledges(HollowTheme hollow, int memberCount) {
    final stats = _stats;
    if (stats == null) return const SizedBox.shrink();

    final avgPledge = memberCount > 0
        ? stats.totalPledgedBytes ~/ BigInt.from(memberCount)
        : BigInt.zero;

    return Row(children: [
      Expanded(
        child: Text('$memberCount members contributing',
            style: HollowTypography.body.copyWith(color: hollow.textPrimary)),
      ),
      Text('Avg: ${_formatBytes(avgPledge)}',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
    ]);
  }

  Widget _storageBar(double fraction, Color color, HollowTheme hollow) {
    final clamped = fraction.clamp(0.0, 1.0);
    final barColor = fraction > 0.9
        ? hollow.error
        : fraction > 0.7 ? hollow.warning : color;

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: Stack(children: [
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
        ]),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String title;
  final Widget child;

  const _SectionCard({
    required this.hollow,
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: hollow.accent),
            const SizedBox(width: HollowSpacing.sm),
            Text(title, style: HollowTypography.caption.copyWith(
              color: hollow.accent,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            )),
          ]),
          const SizedBox(height: HollowSpacing.md),
          child,
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/disk_space.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_card.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
  // Static, so it survives dialog open and close and shows instantly on
  // reopen.
  static final Map<String, crdt_api.StorageStatsFfi> _statsCache = {};
  static final Map<String, String> _retentionFilesCache = {};
  static final Map<String, String> _retentionMessagesCache = {};
  static int _diskFreeBytesCache = 0;

  crdt_api.StorageStatsFfi? _stats;
  String _retentionFiles = '365d';
  String _retentionMessages = 'permanent';
  int _diskFreeBytes = 0;

  @override
  void initState() {
    super.initState();
    _stats = _statsCache[widget.serverId];
    _retentionFiles = _retentionFilesCache[widget.serverId] ?? '365d';
    _retentionMessages = _retentionMessagesCache[widget.serverId] ?? 'permanent';
    _diskFreeBytes = _diskFreeBytesCache;
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

      _statsCache[widget.serverId] = stats;
      _retentionFilesCache[widget.serverId] = retFiles.isNotEmpty ? retFiles : '365d';
      _retentionMessagesCache[widget.serverId] = retMessages.isNotEmpty ? retMessages : 'permanent';
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

  // The drive that holds the data root, which a profile or portable mode can
  // put anywhere; never a fixed C: or /.
  Future<int> _getDiskFreeBytes() async =>
      (await freeBytesAt(hollowDataDir)) ?? 0;

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

  /// Returns the (k, m) erasure parameters for the current member count, from
  /// which the redundancy overhead is (k+m)/k.
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
      title: 'Storage dashboard',
      showClose: true,
      width: 600,
      content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...[
              // Full width below the erasure-coding threshold, side by side
              // above it.
              if (memberCount < 6)
                _buildSection(
                  hollow,
                  'Server Storage',
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
                          _buildServerOverview(hollow, memberCount),
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.md),
                      Expanded(
                        child: _buildSection(
                          hollow,
                          'Your Storage',
                          _buildYourStorage(hollow),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: HollowSpacing.md),

              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildSection(
                        hollow,
                        'Retention Policy',
                        _buildRetentionPolicy(hollow),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.md),
                    Expanded(
                      child: _buildSection(
                        hollow,
                        'Vault Health',
                        _buildVaultHealth(hollow, vaultStatus, memberCount),
                      ),
                    ),
                  ],
                ),
              ),

              if (memberCount >= 6) ...[
                const SizedBox(height: HollowSpacing.md),
                _buildSection(
                  hollow,
                  'Member Pledges',
                  _buildMemberPledges(hollow, memberCount),
                ),
              ],
            ],
          ],
        ),
    );
  }

  Widget _buildSection(
    HollowTheme hollow,
    String title,
    Widget content,
  ) {
    return HollowCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowSectionHeader(title, dense: true),
          const SizedBox(height: HollowSpacing.xs),
          content,
        ],
      ),
    );
  }

  Widget _buildServerOverview(HollowTheme hollow, int memberCount) {
    final stats = _stats;
    final totalUsed = stats?.totalUsedBytes.toDouble() ?? 0;

    if (memberCount < 6) {
      // Full replication: the bar is server data against total disk.
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

    // Erasure coding: the bar is server data against effective usable capacity,
    // which is the pledged total scaled by k / (k + m) for redundancy.
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
              style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
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
    final saved = await editStoragePledge(
        context, widget.serverId, _stats?.myPledgeBytes);
    if (!saved || !mounted) return;
    HollowToast.show(context, 'Pledge saved', type: HollowToastType.success);
    _loadData();
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
          borderRadius: BorderRadius.circular(hollow.radiusXs),
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

  Future<void> _editRetention(HollowTheme hollow, String key, String currentValue) async {
    final saved =
        await editRetentionPolicy(context, widget.serverId, key, currentValue);
    if (!saved || !mounted) return;
    HollowToast.show(context, 'Retention saved', type: HollowToastType.success);
    _loadData();
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
          ),
        ),
      ],
    );
  }

  Widget _retentionRow(HollowTheme hollow, String label, String settingKey, String policy, {bool canEdit = true}) {
    return HollowPressable(
      onTap: canEdit ? () => _editRetention(hollow, settingKey, policy) : null,
      borderRadius: BorderRadius.circular(hollow.radiusXs),
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
      // Full replication mode.
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
            ),
          ),
        ],
      );
    }

    // Erasure coding mode.
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
          ),
        ),
      ],
    );
  }

  Widget _storageBar(double fraction, Color color, HollowTheme hollow) {
    return StorageUsageBar(fraction: fraction, color: color);
  }
}

/// Asks for this device's storage pledge and saves it, in the dialog: loading
/// while the write runs, the reason at the field when it fails or the number
/// is too small. True once saved. Desktop and phone both ask through this.
Future<bool> editStoragePledge(
    BuildContext context, String serverId, BigInt? currentBytes) async {
  final currentMb = currentBytes == null
      ? 512
      : currentBytes ~/ BigInt.from(1024 * 1024);
  final saved = await promptForName(
    context: context,
    title: 'Set storage pledge',
    confirmLabel: 'Save',
    hintText: 'At least 512',
    initial: '$currentMb',
    description: "The space, in MB, this device keeps for this server's files.",
    validator: (text) {
      final mb = int.tryParse(text);
      if (mb == null) return 'Enter a number of MB, like 1024.';
      if (mb < kMinPledgeMb) return 'Pledge at least $kMinPledgeMb MB.';
      return null;
    },
    onSubmit: (text) => crdt_api.setStoragePledge(
      serverId: serverId,
      pledgeBytes: BigInt.from(int.parse(text)) * BigInt.from(1024 * 1024),
    ),
  );
  return saved != null;
}

/// The smallest pledge a member can make, in MB.
const kMinPledgeMb = 512;

const _retentionOptions = [
  ('permanent', 'Permanent'),
  ('30d', '30 days'),
  ('90d', '90 days'),
  ('180d', '180 days'),
  ('365d', '365 days'),
];

/// Picks a retention policy and saves it, in the dialog: the pick loads,
/// closes on success and says why it failed otherwise. True once saved.
/// Desktop and phone both ask through this.
Future<bool> editRetentionPolicy(BuildContext context, String serverId,
    String key, String currentValue) async {
  final saved = await showHollowDialog<bool>(
    context: context,
    builder: (_) => _RetentionPicker(
      serverId: serverId,
      settingKey: key,
      currentValue: currentValue,
    ),
  );
  return saved ?? false;
}

class _RetentionPicker extends StatefulWidget {
  final String serverId;
  final String settingKey;
  final String currentValue;

  const _RetentionPicker({
    required this.serverId,
    required this.settingKey,
    required this.currentValue,
  });

  @override
  State<_RetentionPicker> createState() => _RetentionPickerState();
}

class _RetentionPickerState extends State<_RetentionPicker>
    with HollowDialogAction {
  String? _saving;

  bool _isCurrent(String value) =>
      value == widget.currentValue ||
      (widget.currentValue.isEmpty && value == 'permanent');

  Future<void> _pick(String value) async {
    if (actionRunning) return;
    if (_isCurrent(value)) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _saving = value);
    final done = await runDialogAction(() async {
      await crdt_api.updateServerSetting(
        serverId: widget.serverId,
        key: widget.settingKey,
        value: value,
      );
      // Forward-only: the stamp is what keeps pruning off anything created
      // before the policy changed.
      await crdt_api.updateServerSetting(
        serverId: widget.serverId,
        key: '${widget.settingKey}_since',
        value: (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      );
    }, fallback: "Couldn't save the retention policy. Try again.");
    if (done && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.settingKey;
    final title = key == 'retention_files'
        ? 'File retention'
        : key == 'retention_messages'
            ? 'Message retention'
            : 'Voice retention';
    return HollowDialog(
      title: title,
      showClose: true,
      busy: actionRunning,
      error: actionError,
      content: Wrap(
        spacing: HollowSpacing.sm,
        runSpacing: HollowSpacing.sm,
        children: [
          for (final (value, label) in _retentionOptions)
            HollowChip(
              label: label,
              selected: actionRunning ? _saving == value : _isCurrent(value),
              onTap: actionRunning ? null : () => _pick(value),
            ),
        ],
      ),
    );
  }
}

/// A server's share of a storage measure, drawn by desktop and phone alike.
class StorageUsageBar extends StatelessWidget {
  final double fraction;
  final Color color;

  const StorageUsageBar({super.key, required this.fraction, required this.color});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final clamped = fraction.clamp(0.0, 1.0);
    final barColor = fraction > 0.9
        ? hollow.error
        : fraction > 0.7
            ? hollow.warning
            : color;

    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusXs),
      child: SizedBox(
        height: 8,
        child: Stack(
          children: [
            Container(color: hollow.border),
            TweenAnimationBuilder<double>(
              tween: Tween(end: clamped),
              duration: HollowDurations.slow,
              curve: HollowCurves.enter,
              builder: (context, value, _) => FractionallySizedBox(
                widthFactor: value,
                child: Container(
                  decoration: BoxDecoration(
                    color: barColor,
                    borderRadius: BorderRadius.circular(hollow.radiusXs),
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

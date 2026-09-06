import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_file_status_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/dialogs/shard_bundle_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Right panel for the Vault Files tab: every server the user belongs to, with
/// expandable sections listing its vault files and their shard status.
class VaultFilesView extends ConsumerWidget {
  const VaultFilesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider);

    if (servers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.hardDrive, size: 40, color: hollow.textSecondary),
            const SizedBox(height: HollowSpacing.md),
            Text(
              'No servers',
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.xs,
          ),
          child: Row(
            children: [
              _ActionButton(
                icon: LucideIcons.logIn,
                label: 'Join Recovery Pool',
                onTap: () => showJoinRecoveryPoolDialog(context),
                hollow: hollow,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.xs,
            ),
            itemCount: servers.length,
            itemBuilder: (context, index) {
              final entry = servers.entries.elementAt(index);
              return _ServerVaultSection(
                serverId: entry.key,
                server: entry.value,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Expandable section for one server showing its vault files.
class _ServerVaultSection extends ConsumerStatefulWidget {
  final String serverId;
  final ServerInfo server;

  const _ServerVaultSection({
    required this.serverId,
    required this.server,
  });

  @override
  ConsumerState<_ServerVaultSection> createState() =>
      _ServerVaultSectionState();
}

class _ServerVaultSectionState extends ConsumerState<_ServerVaultSection> {
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final statusAsync = ref.watch(vaultFileStatusProvider(widget.serverId));

    // Set once, then the user's toggle takes over.
    if (_expanded == null && statusAsync.hasValue) {
      _expanded = statusAsync.value!.isNotEmpty;
    }
    final expanded = _expanded ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowPressable(
          onTap: () => setState(() => _expanded = !expanded),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 16,
                color: hollow.textSecondary,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Icon(LucideIcons.server, size: 16, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  widget.server.name,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              statusAsync.when(
                data: (files) {
                  if (files.isEmpty) {
                    return Text(
                      'No vault files',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                    );
                  }
                  final recoverable =
                      files.where((f) => f.isReconstructable).length;
                  return Text(
                    '$recoverable/${files.length} recoverable',
                    style: HollowTypography.caption.copyWith(
                      color: recoverable == files.length
                          ? const Color(0xFF4CAF50)
                          : hollow.textSecondary,
                      fontSize: 11,
                    ),
                  );
                },
                loading: () => const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                ),
                error: (_, _) => Text(
                  'Error',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.error,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),

        if (expanded)
          statusAsync.when(
            data: (files) {
              if (files.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.only(
                    left: HollowSpacing.xxl,
                    bottom: HollowSpacing.md,
                  ),
                  child: Text(
                    'No erasure-coded files for this server.',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.lg,
                      vertical: HollowSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        _ActionButton(
                          icon: LucideIcons.download,
                          label: 'Export Shards',
                          onTap: () => showExportShardsDialog(
                            context,
                            serverId: widget.serverId,
                            serverName: widget.server.name,
                            shardCount: files.fold<int>(
                              0, (sum, f) => sum + f.localShardCount),
                          ),
                          hollow: hollow,
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        _ActionButton(
                          icon: LucideIcons.upload,
                          label: 'Import Shards',
                          onTap: () => showImportShardsDialog(
                            context,
                            onImported: () => ref.invalidate(
                              vaultFileStatusProvider(widget.serverId),
                            ),
                          ),
                          hollow: hollow,
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        _ActionButton(
                          icon: LucideIcons.shield,
                          label: 'Start Recovery Pool',
                          onTap: () => showInitiateRecoveryPoolDialog(
                            context,
                            serverId: widget.serverId,
                            serverName: widget.server.name,
                          ),
                          hollow: hollow,
                        ),
                      ],
                    ),
                  ),
                  _buildGroupedFileList(files, hollow),
                ],
              );
            },
            loading: () => const Padding(
              padding: EdgeInsets.all(HollowSpacing.lg),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(HollowSpacing.md),
              child: Text(
                'Failed to load: $e',
                style: HollowTypography.caption.copyWith(
                  color: hollow.error,
                  fontSize: 12,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGroupedFileList(List<VaultFileStatus> files, HollowTheme hollow) {
    final groups = <_FileCategory, List<VaultFileStatus>>{};
    for (final file in files) {
      final cat = _categorize(file.fileName);
      (groups[cat] ??= []).add(file);
    }

    for (final list in groups.values) {
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }

    const order = _FileCategory.values;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cat in order)
          if (groups.containsKey(cat)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HollowSpacing.lg, HollowSpacing.sm, HollowSpacing.lg, HollowSpacing.xxs,
              ),
              child: Row(
                children: [
                  Icon(cat.icon, size: 14, color: hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    cat.label,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Text(
                    '(${groups[cat]!.length})',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            for (final file in groups[cat]!)
              _VaultFileRow(file: file, hollow: hollow),
          ],
        const SizedBox(height: HollowSpacing.md),
      ],
    );
  }

  static _FileCategory _categorize(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'mp4' || 'webm' || 'mov' || 'mkv' || 'avi' || 'm4v' => _FileCategory.videos,
      'mp3' || 'ogg' || 'wav' || 'flac' || 'm4a' || 'aac' || 'wma' => _FileCategory.audio,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'svg' => _FileCategory.images,
      'pdf' || 'doc' || 'docx' || 'xls' || 'xlsx' || 'txt' || 'md' => _FileCategory.documents,
      _ => _FileCategory.other,
    };
  }
}

enum _FileCategory {
  videos('Videos', LucideIcons.fileVideo),
  audio('Audio', LucideIcons.fileAudio),
  images('Images', LucideIcons.image),
  documents('Documents', LucideIcons.fileText),
  other('Other', LucideIcons.file);

  final String label;
  final IconData icon;
  const _FileCategory(this.label, this.icon);
}

/// A single vault file row with shard status indicator.
class _VaultFileRow extends StatelessWidget {
  final VaultFileStatus file;
  final HollowTheme hollow;

  const _VaultFileRow({required this.file, required this.hollow});

  @override
  Widget build(BuildContext context) {
    final shardText = '${file.localShardCount}/${file.k} shards';
    final Color badgeColor;
    final Color badgeBg;
    if (file.isReconstructable) {
      badgeColor = const Color(0xFF4CAF50);
      badgeBg = const Color(0xFF4CAF50).withValues(alpha: 0.12);
    } else if (file.localShardCount > 0) {
      badgeColor = const Color(0xFFFFA726);
      badgeBg = const Color(0xFFFFA726).withValues(alpha: 0.12);
    } else {
      badgeColor = hollow.textSecondary;
      badgeBg = hollow.textSecondary.withValues(alpha: 0.08);
    }

    final progress = file.k > 0 ? file.localShardCount / file.k : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.xxs,
      ),
      child: Container(
        padding: const EdgeInsets.all(HollowSpacing.md),
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: hollow.border),
        ),
        child: Row(
          children: [
            Icon(
              _iconForFile(file.fileName),
              size: 20,
              color: hollow.accent,
            ),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    file.fileName,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: HollowSpacing.xxs),
                  Row(
                    children: [
                      Text(
                        '${_formatDate(file.createdAt)}  ·  ${_formatSize(file.originalSize)}',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      Expanded(
                        child: SizedBox(
                          height: 3,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: progress.clamp(0.0, 1.0),
                              backgroundColor: hollow.border,
                              valueColor:
                                  AlwaysStoppedAnimation(badgeColor),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
              ),
              child: Text(
                shardText,
                style: HollowTypography.caption.copyWith(
                  color: badgeColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconForFile(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'mp4' || 'webm' || 'mov' || 'mkv' || 'avi' => LucideIcons.fileVideo,
      'mp3' || 'ogg' || 'wav' || 'flac' || 'm4a' => LucideIcons.fileAudio,
      'pdf' => LucideIcons.fileText,
      'zip' || 'rar' || '7z' || 'tar' => LucideIcons.fileArchive,
      _ => LucideIcons.file,
    };
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _formatDate(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    return '${_months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// Small action button used for Export/Import in the vault files view.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final HollowTheme hollow;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      backgroundColor: hollow.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

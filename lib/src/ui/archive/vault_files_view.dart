import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_file_status_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/dialogs/shard_bundle_dialog.dart';
import 'package:hollow/src/ui/share/share_card.dart' show ShareCard;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Vault files: every server you belong to, each opening to the files it keeps
/// spread across its members and how many shards of each this device holds.
class VaultFilesView extends ConsumerWidget {
  const VaultFilesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);

    if (servers.isEmpty) {
      return const HollowEmptyState(
        glyph: LucideIcons.hardDrive,
        title: 'No vault files yet',
        description: 'A server keeps its large files as shards across its '
            'members. Join one and its files show up here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      children: [
        for (final entry in servers.entries)
          _ServerVaultSection(serverId: entry.key, server: entry.value),
      ],
    );
  }
}

/// One server, opening to its vault files. Open by default when it has any.
class _ServerVaultSection extends ConsumerStatefulWidget {
  final String serverId;
  final ServerInfo server;

  const _ServerVaultSection({required this.serverId, required this.server});

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

    final Widget status = statusAsync.when(
      loading: () => const HollowSpinner(),
      error: (_, _) => Text("Didn't load",
          style: HollowTypography.caption.copyWith(color: hollow.error)),
      data: (files) {
        if (files.isEmpty) {
          return Text('No vault files',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary));
        }
        final recoverable = files.where((f) => f.isReconstructable).length;
        return Text(
          '$recoverable of ${files.length} recoverable',
          style: HollowTypography.caption.copyWith(
            color: recoverable == files.length
                ? hollow.success
                : hollow.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowPressable(
          onTap: () => setState(() => _expanded = !expanded),
          subtle: true,
          semanticLabel:
              '${widget.server.name}, ${expanded ? 'collapse' : 'expand'}',
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
          child: Row(
            children: [
              Icon(
                expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 16,
                color: hollow.textTertiary,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  widget.server.name,
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              status,
            ],
          ),
        ),
        if (expanded)
          statusAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(HollowSpacing.lg),
              child: Center(child: HollowSpinner.medium()),
            ),
            error: (_, _) => Padding(
              padding: const EdgeInsets.fromLTRB(HollowSpacing.xxl,
                  HollowSpacing.xs, HollowSpacing.md, HollowSpacing.md),
              child: HollowEmptyState(
                dense: true,
                title: "This server's vault files didn't load",
                action: HollowButton.ghost(
                  compact: true,
                  onPressed: () => ref
                      .invalidate(vaultFileStatusProvider(widget.serverId)),
                  child: const Text('Try again'),
                ),
              ),
            ),
            data: (files) => files.isEmpty
                ? const Padding(
                    padding: EdgeInsets.fromLTRB(HollowSpacing.xxl,
                        HollowSpacing.xs, HollowSpacing.md, HollowSpacing.md),
                    child: HollowEmptyState(
                      dense: true,
                      title: 'No vault files on this server yet',
                    ),
                  )
                : _files(files),
          ),
        const SizedBox(height: HollowSpacing.sm),
      ],
    );
  }

  Widget _files(List<VaultFileStatus> files) {
    final groups = <_FileCategory, List<VaultFileStatus>>{};
    for (final file in files) {
      (groups[_categorize(file.fileName)] ??= []).add(file);
    }
    for (final list in groups.values) {
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }

    return Padding(
      // Under the server name, past the chevron.
      padding: const EdgeInsets.only(left: HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md, vertical: HollowSpacing.xs),
            child: Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: [
                HollowButton.ghost(
                  compact: true,
                  icon: const Icon(LucideIcons.download, size: 14),
                  onPressed: () => showExportShardsDialog(
                    context,
                    serverId: widget.serverId,
                    serverName: widget.server.name,
                    shardCount:
                        files.fold<int>(0, (sum, f) => sum + f.localShardCount),
                  ),
                  child: const Text('Export shards'),
                ),
                HollowButton.ghost(
                  compact: true,
                  icon: const Icon(LucideIcons.upload, size: 14),
                  onPressed: () => showImportShardsDialog(
                    context,
                    onImported: () => ref
                        .invalidate(vaultFileStatusProvider(widget.serverId)),
                  ),
                  child: const Text('Import shards'),
                ),
                HollowButton.ghost(
                  compact: true,
                  icon: const Icon(LucideIcons.shield, size: 14),
                  onPressed: () => showInitiateRecoveryPoolDialog(
                    context,
                    serverId: widget.serverId,
                    serverName: widget.server.name,
                  ),
                  child: const Text('Start a recovery pool'),
                ),
              ],
            ),
          ),
          for (final cat in _FileCategory.values)
            if (groups.containsKey(cat)) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(HollowSpacing.md,
                    HollowSpacing.sm, HollowSpacing.md, 0),
                child: HollowSectionHeader(cat.label,
                    dense: true, count: '${groups[cat]!.length}'),
              ),
              for (final file in groups[cat]!) _VaultFileRow(file: file),
            ],
        ],
      ),
    );
  }

  static _FileCategory _categorize(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    return switch (ext) {
      'mp4' || 'webm' || 'mov' || 'mkv' || 'avi' || 'm4v' =>
        _FileCategory.videos,
      'mp3' || 'ogg' || 'wav' || 'flac' || 'm4a' || 'aac' || 'wma' =>
        _FileCategory.audio,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'svg' =>
        _FileCategory.images,
      'pdf' || 'doc' || 'docx' || 'xls' || 'xlsx' || 'txt' || 'md' =>
        _FileCategory.documents,
      _ => _FileCategory.other,
    };
  }
}

enum _FileCategory {
  videos('Videos'),
  audio('Audio'),
  images('Images'),
  documents('Documents'),
  other('Other');

  final String label;
  const _FileCategory(this.label);
}

/// One vault file and how many of the shards needed to rebuild it are here.
class _VaultFileRow extends StatelessWidget {
  final VaultFileStatus file;

  const _VaultFileRow({required this.file});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final kind = file.isReconstructable
        ? HollowBadgeKind.success
        : (file.localShardCount > 0
            ? HollowBadgeKind.warning
            : HollowBadgeKind.neutral);
    final created =
        DateTime.fromMillisecondsSinceEpoch(file.createdAt * 1000);

    return HollowListRow(
      leading: Icon(_iconForFile(file.fileName),
          size: 20, color: hollow.textSecondary),
      title: file.fileName,
      subtitle: '${calendarDateLabel(created)} · '
          '${ShareCard.formatSize(file.originalSize)}',
      trailing: HollowBadge(
        file.isReconstructable
            ? 'Recoverable'
            : '${file.localShardCount} of ${file.k} shards',
        kind: kind,
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
}

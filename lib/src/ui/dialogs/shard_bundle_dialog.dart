import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:path_provider/path_provider.dart' as path_provider;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Show the export shards dialog for a server.
void showExportShardsDialog(
  BuildContext context, {
  required String serverId,
  required String serverName,
  required int shardCount,
}) {
  showHollowDialog(
    context: context,
    builder: (_) => _ExportShardsDialog(
      serverId: serverId,
      serverName: serverName,
      shardCount: shardCount,
    ),
  );
}

class _ExportShardsDialog extends StatefulWidget {
  final String serverId;
  final String serverName;
  final int shardCount;

  const _ExportShardsDialog({
    required this.serverId,
    required this.serverName,
    required this.shardCount,
  });

  @override
  State<_ExportShardsDialog> createState() => _ExportShardsDialogState();
}

class _ExportShardsDialogState extends State<_ExportShardsDialog> {
  bool _exporting = false;

  Future<void> _export() async {
    final safeName = widget.serverName
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final fileName = '$safeName.hollow-shards';
    final isMobile = Platform.isAndroid || Platform.isIOS;

    String outputPath;
    if (isMobile) {
      final tmpDir = await path_provider.getTemporaryDirectory();
      outputPath = '${tmpDir.path}/$fileName';
    } else {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save shard bundle',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['hollow-shards'],
      );
      if (savePath == null || !mounted) return;
      outputPath = savePath;
    }

    setState(() => _exporting = true);

    try {
      final sizeBytes = await archive_api.exportServerShards(
        serverId: widget.serverId,
        outputPath: outputPath,
      );

      if (isMobile) {
        final bytes = await File(outputPath).readAsBytes();
        final savedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save shard bundle',
          fileName: fileName,
          bytes: bytes,
        );
        try { await File(outputPath).delete(); } catch (_) {}
        if (savedPath == null) {
          if (mounted) setState(() => _exporting = false);
          return;
        }
      }

      final sizeMb = (sizeBytes.toInt() / (1024 * 1024)).toStringAsFixed(1);
      final sizeKb = (sizeBytes.toInt() / 1024).toStringAsFixed(0);
      final sizeStr =
          sizeBytes.toInt() > 1024 * 1024 ? '$sizeMb MB' : '$sizeKb KB';

      if (mounted) {
        Navigator.of(context).pop();
        HollowToast.show(
          context,
          'Shards exported: $sizeStr',
          type: HollowToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _exporting = false);
        HollowToast.show(
          context,
          'Export failed: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowDialog(
      title: 'Export shards',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.server, size: 16, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  widget.serverName,
                  style: HollowTypography.label.copyWith(
                    color: hollow.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowDialogText(
            'Export ${widget.shardCount} vault shards as a .hollow-shards bundle. '
            'Share this file with other ex-members so they can import your '
            'shards and reconstruct files.',
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _exporting ? null : _export,
          loading: _exporting,
          icon: const Icon(LucideIcons.download, size: 14),
          child: const Text('Export'),
        ),
      ],
    );
  }
}

/// Shows the import shards dialog, which picks a `.hollow-shards` file.
void showImportShardsDialog(
  BuildContext context, {
  VoidCallback? onImported,
}) {
  showHollowDialog(
    context: context,
    builder: (_) => _ImportShardsDialog(onImported: onImported),
  );
}

class _ImportShardsDialog extends StatefulWidget {
  final VoidCallback? onImported;

  const _ImportShardsDialog({this.onImported});

  @override
  State<_ImportShardsDialog> createState() => _ImportShardsDialogState();
}

class _ImportShardsDialogState extends State<_ImportShardsDialog> {
  bool _importing = false;
  archive_api.ShardImportResultFfi? _result;

  Future<void> _pickAndImport() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select shard bundle',
      type: FileType.custom,
      allowedExtensions: ['hollow-shards'],
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    final path = picked.files.first.path;
    if (path == null) return;

    setState(() => _importing = true);

    try {
      final result = await archive_api.importServerShards(
        archivePath: path,
      );
      if (mounted) {
        setState(() {
          _importing = false;
          _result = result;
        });
        widget.onImported?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _importing = false);
        HollowToast.show(
          context,
          'Import failed: $e',
          type: HollowToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (_result != null) {
      return _buildResult(hollow);
    }

    return HollowDialog(
      title: 'Import shards',
      content: const HollowDialogText(
        'Select a .hollow-shards bundle from another ex-member. '
        'New manifests and shards will be imported into your local vault.',
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _importing ? null : _pickAndImport,
          loading: _importing,
          icon: const Icon(LucideIcons.upload, size: 14),
          child: const Text('Select file'),
        ),
      ],
    );
  }

  Widget _buildResult(HollowTheme hollow) {
    final r = _result!;
    return HollowDialog(
      title: 'Import complete',
      showClose: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResultRow(
            label: 'Server',
            value: r.serverId,
            hollow: hollow,
          ),
          const SizedBox(height: HollowSpacing.sm),
          _ResultRow(
            label: 'Manifests imported',
            value: '${r.manifestsImported}',
            hollow: hollow,
          ),
          const SizedBox(height: HollowSpacing.xs),
          _ResultRow(
            label: 'Shards imported',
            value: '${r.shardsImported}',
            hollow: hollow,
          ),
          const SizedBox(height: HollowSpacing.xs),
          _ResultRow(
            label: 'Shards skipped',
            value: '${r.shardsSkipped} (already had)',
            hollow: hollow,
          ),
          const SizedBox(height: HollowSpacing.sm),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Icon(LucideIcons.checkCircle, size: 16, color: hollow.success),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  '${r.newReconstructable} files now reconstructable',
                  style: HollowTypography.label.copyWith(
                    color: hollow.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final String label;
  final String value;
  final HollowTheme hollow;

  const _ResultRow({
    required this.label,
    required this.value,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textSecondary,
          ),
        ),
        Text(
          value,
          style: HollowTypography.label.copyWith(
            color: hollow.textPrimary,
          ),
        ),
      ],
    );
  }
}

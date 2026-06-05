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

// ── Export shards dialog ───────────────────────────────────────

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
        dialogTitle: 'Save Shard Bundle',
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
          dialogTitle: 'Save Shard Bundle',
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
          'Shards exported — $sizeStr',
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
      title: 'Export Shards',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.server, size: 16, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  widget.serverName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Export ${widget.shardCount} vault shards as a .hollow-shards bundle. '
            'Share this file with other ex-members so they can import your '
            'shards and reconstruct files.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _exporting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          onPressed: _exporting ? null : _export,
          icon: _exporting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(hollow.textPrimary),
                  ),
                )
              : const Icon(LucideIcons.download, size: 14),
          child: Text(_exporting ? 'Exporting...' : 'Export'),
        ),
      ],
    );
  }
}

// ── Import shards dialog ───────────────────────────────────────

/// Show the import shards dialog. Lets user pick a `.hollow-shards` file.
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
      dialogTitle: 'Select Shard Bundle',
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
      title: 'Import Shards',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Select a .hollow-shards bundle from another ex-member. '
            'New manifests and shards will be imported into your local vault.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          onPressed: _importing ? null : _pickAndImport,
          icon: _importing
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(hollow.textPrimary),
                  ),
                )
              : const Icon(LucideIcons.upload, size: 14),
          child: Text(_importing ? 'Importing...' : 'Select File'),
        ),
      ],
    );
  }

  Widget _buildResult(HollowTheme hollow) {
    final r = _result!;
    return HollowDialog(
      title: 'Import Complete',
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
          Container(
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: const Color(0xFF4CAF50).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: Row(
              children: [
                const Icon(LucideIcons.checkCircle, size: 16, color: Color(0xFF4CAF50)),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(
                    '${r.newReconstructable} files now reconstructable',
                    style: HollowTypography.body.copyWith(
                      color: const Color(0xFF4CAF50),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.filled(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
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
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 12,
          ),
        ),
        Text(
          value,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

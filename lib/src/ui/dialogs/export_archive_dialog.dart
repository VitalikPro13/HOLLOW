import 'dart:convert';
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
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Show the export archive dialog for a DM, channel, or server.
void showExportArchiveDialog(
  BuildContext context, {
  required bool isDm,
  bool isServer = false,
  String? peerId,
  String? serverId,
  String? channelId,
  String? channelName,
  String? serverName,
  List<Map<String, String>>? channels,
  required String name,
  required int messageCount,
}) {
  showHollowDialog(
    context: context,
    builder: (dialogContext) => _ExportArchiveDialogContent(
      isDm: isDm,
      isServer: isServer,
      peerId: peerId,
      serverId: serverId,
      channelId: channelId,
      channelName: channelName,
      serverName: serverName,
      channels: channels,
      name: name,
      messageCount: messageCount,
    ),
  );
}

class _ExportArchiveDialogContent extends StatefulWidget {
  final bool isDm;
  final bool isServer;
  final String? peerId;
  final String? serverId;
  final String? channelId;
  final String? channelName;
  final String? serverName;
  final List<Map<String, String>>? channels;
  final String name;
  final int messageCount;

  const _ExportArchiveDialogContent({
    required this.isDm,
    this.isServer = false,
    this.peerId,
    this.serverId,
    this.channelId,
    this.channelName,
    this.serverName,
    this.channels,
    required this.name,
    required this.messageCount,
  });

  @override
  State<_ExportArchiveDialogContent> createState() =>
      _ExportArchiveDialogContentState();
}

class _ExportArchiveDialogContentState
    extends State<_ExportArchiveDialogContent> {
  String _fileMode = 'full';
  bool _exporting = false;

  Future<void> _export() async {
    final safeName = widget.name
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final fileName = '$safeName.hollow-archive';
    final isMobile = Platform.isAndroid || Platform.isIOS;

    String outputPath;
    if (isMobile) {
      final tmpDir = await path_provider.getTemporaryDirectory();
      outputPath = '${tmpDir.path}/$fileName';
    } else {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save archive',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['hollow-archive'],
      );
      if (savePath == null || !mounted) return;
      outputPath = savePath;
    }

    setState(() => _exporting = true);

    try {
      final BigInt sizeBytes;
      if (widget.isServer) {
        sizeBytes = await archive_api.exportServerArchive(
          serverId: widget.serverId!,
          serverName: widget.serverName ?? widget.name,
          channelsJson: jsonEncode(widget.channels ?? []),
          outputPath: outputPath,
          fileMode: _fileMode,
        );
      } else if (widget.isDm) {
        sizeBytes = await archive_api.exportDmArchive(
          peerId: widget.peerId!,
          outputPath: outputPath,
          fileMode: _fileMode,
        );
      } else {
        sizeBytes = await archive_api.exportChannelArchive(
          serverId: widget.serverId!,
          channelId: widget.channelId!,
          channelName: widget.channelName,
          outputPath: outputPath,
          fileMode: _fileMode,
        );
      }

      if (isMobile) {
        final bytes = await File(outputPath).readAsBytes();
        final savedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save archive',
          fileName: fileName,
          bytes: bytes,
        );
        try { await File(outputPath).delete(); } catch (_) {}
        if (savedPath == null) {
          if (mounted) {
            setState(() => _exporting = false);
          }
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
          'Archive exported: $sizeStr',
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

  static const _fileModes = <(String, String, String)>[
    ('full', 'Full', 'Include all files (largest)'),
    ('images_only', 'Images only', 'Include images, skip videos and large files'),
    ('placeholder', 'Placeholder', 'No files, just metadata (smallest)'),
  ];

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final typeIcon = widget.isServer
        ? LucideIcons.server
        : widget.isDm
            ? LucideIcons.messageSquare
            : LucideIcons.hash;
    final modeDescription =
        _fileModes.firstWhere((m) => m.$1 == _fileMode).$3;

    return HollowDialog(
      title: 'Export archive',
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            child: Row(
              children: [
                Icon(typeIcon, size: 16, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(
                    widget.name,
                    style: HollowTypography.label.copyWith(
                      color: hollow.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.messageCount > 0)
                  Text(
                    '${widget.messageCount} messages',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'File mode'),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              for (var i = 0; i < _fileModes.length; i++) ...[
                if (i > 0) const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: HollowChip(
                    expand: true,
                    label: _fileModes[i].$2,
                    selected: _fileMode == _fileModes[i].$1,
                    onTap: () => setState(() => _fileMode = _fileModes[i].$1),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            modeDescription,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Icon(LucideIcons.shieldCheck,
                  size: 14, color: hollow.textTertiary),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: Text(
                  'Archive will be signed with your Ed25519 key for cryptographic verification.',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textTertiary,
                  ),
                ),
              ),
            ],
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
          icon: Icon(LucideIcons.fileOutput,
              size: 14, color: hollow.textOnAccent),
          child: const Text('Export and sign'),
        ),
      ],
    );
  }
}

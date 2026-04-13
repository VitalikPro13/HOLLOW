import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons/lucide_icons.dart';

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
    // Open save dialog.
    final safeName = widget.name
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .replaceAll(RegExp(r'\s+'), '_')
        .toLowerCase();
    final fileName = '$safeName.hollow-archive';

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Archive',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: ['hollow-archive'],
    );
    if (savePath == null || !mounted) return;

    setState(() => _exporting = true);

    try {
      final BigInt sizeBytes;
      if (widget.isServer) {
        sizeBytes = await archive_api.exportServerArchive(
          serverId: widget.serverId!,
          serverName: widget.serverName ?? widget.name,
          channelsJson: jsonEncode(widget.channels ?? []),
          outputPath: savePath,
          fileMode: _fileMode,
        );
      } else if (widget.isDm) {
        sizeBytes = await archive_api.exportDmArchive(
          peerId: widget.peerId!,
          outputPath: savePath,
          fileMode: _fileMode,
        );
      } else {
        sizeBytes = await archive_api.exportChannelArchive(
          serverId: widget.serverId!,
          channelId: widget.channelId!,
          channelName: widget.channelName,
          outputPath: savePath,
          fileMode: _fileMode,
        );
      }

      final sizeMb = (sizeBytes.toInt() / (1024 * 1024)).toStringAsFixed(1);
      final sizeKb = (sizeBytes.toInt() / 1024).toStringAsFixed(0);
      final sizeStr =
          sizeBytes.toInt() > 1024 * 1024 ? '$sizeMb MB' : '$sizeKb KB';

      if (mounted) {
        Navigator.of(context).pop();
        HollowToast.show(
          context,
          'Archive exported — $sizeStr',
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
    final typeIcon = widget.isServer
        ? LucideIcons.server
        : widget.isDm
            ? LucideIcons.messageSquare
            : LucideIcons.hash;

    return HollowDialog(
      title: 'Export Archive',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Conversation info ──
          Container(
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
            ),
            child: Row(
              children: [
                Icon(typeIcon, size: 16, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(
                    widget.name,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${widget.messageCount} messages',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: HollowSpacing.lg),

          // ── File mode label ──
          Text(
            'File mode',
            style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),

          // ── File mode options ──
          _FileModeOption(
            icon: LucideIcons.hardDrive,
            label: 'Full',
            description: 'Include all files (largest)',
            isSelected: _fileMode == 'full',
            onTap: () => setState(() => _fileMode = 'full'),
          ),
          const SizedBox(height: HollowSpacing.xs),
          _FileModeOption(
            icon: LucideIcons.image,
            label: 'Images only',
            description: 'Include images, skip videos and large files',
            isSelected: _fileMode == 'images_only',
            onTap: () => setState(() => _fileMode = 'images_only'),
          ),
          const SizedBox(height: HollowSpacing.xs),
          _FileModeOption(
            icon: LucideIcons.fileText,
            label: 'Placeholder',
            description: 'No files, just metadata (smallest)',
            isSelected: _fileMode == 'placeholder',
            onTap: () => setState(() => _fileMode = 'placeholder'),
          ),

          const SizedBox(height: HollowSpacing.sm),

          // ── Signed note ──
          Row(
            children: [
              Icon(LucideIcons.shieldCheck,
                  size: 12, color: hollow.accent.withValues(alpha: 0.6)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Archive will be signed with your Ed25519 key for cryptographic verification.',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
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
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          onPressed: _exporting ? null : _export,
          icon: _exporting
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation(hollow.textOnAccent),
                  ),
                )
              : Icon(LucideIcons.fileOutput,
                  size: 14, color: hollow.textOnAccent),
          child: Text(_exporting ? 'Exporting...' : 'Export & Sign'),
        ),
      ],
    );
  }
}

class _FileModeOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;

  const _FileModeOption({
    required this.icon,
    required this.label,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? hollow.accent.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(
            color: isSelected
                ? hollow.accent.withValues(alpha: 0.4)
                : hollow.border,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? hollow.accent : hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: HollowTypography.body.copyWith(
                      color: isSelected
                          ? hollow.accent
                          : hollow.textPrimary,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    description,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(LucideIcons.check, size: 14, color: hollow.accent),
          ],
        ),
      ),
    );
  }
}

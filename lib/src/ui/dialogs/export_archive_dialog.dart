import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/storage_provider.dart' show formatBytes;
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/export_to_file.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

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
    extends State<_ExportArchiveDialogContent> with HollowDialogAction {
  String _fileMode = 'full';

  Future<BigInt> _write(String outputPath) {
    if (widget.isServer) {
      return archive_api.exportServerArchive(
        serverId: widget.serverId!,
        serverName: widget.serverName ?? widget.name,
        channelsJson: jsonEncode(widget.channels ?? []),
        outputPath: outputPath,
        fileMode: _fileMode,
      );
    }
    if (widget.isDm) {
      return archive_api.exportDmArchive(
        peerId: widget.peerId!,
        outputPath: outputPath,
        fileMode: _fileMode,
      );
    }
    return archive_api.exportChannelArchive(
      serverId: widget.serverId!,
      channelId: widget.channelId!,
      channelName: widget.channelName,
      outputPath: outputPath,
      fileMode: _fileMode,
    );
  }

  Future<void> _export() async {
    int? size;
    final ok = await runDialogAction(
      () async => size = await exportToFile(
        fileName: '${exportFileStem(widget.name)}.hollow-archive',
        extension: 'hollow-archive',
        pickerTitle: 'Save archive',
        write: _write,
      ),
      fallback: "Couldn't export the archive. Try again.",
    );
    if (!ok || !mounted) return;
    if (size == null) {
      // The picker was cancelled: nothing happened, so nothing to say.
      setState(() => actionRunning = false);
      return;
    }
    Navigator.of(context).pop();
    HollowToast.show(context, 'Archive exported (${formatBytes(size!)})',
        type: HollowToastType.success);
  }

  static const _fileModes = <(String, String, String)>[
    ('full', 'Full', 'Includes every file. The largest archive.'),
    ('images_only', 'Images only',
        'Includes images, and leaves out videos and large files.'),
    ('placeholder', 'Messages only',
        "Keeps each file's name, not the file. The smallest archive."),
  ];

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final modeDescription =
        _fileModes.firstWhere((m) => m.$1 == _fileMode).$3;
    final count = widget.messageCount;

    return HollowDialog(
      title: 'Export ${widget.name}',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(count > 0
              ? 'Saves ${_countLabel(count)} to one file. The archive is '
                  'signed, so anyone can check it came from you.'
              : 'Saves this conversation to one file. The archive is signed, '
                  'so anyone can check it came from you.'),
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'Files'),
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
                    onTap: actionRunning
                        ? null
                        : () => setState(() => _fileMode = _fileModes[i].$1),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            modeDescription,
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _export,
          loading: actionRunning,
          child: const Text('Export and sign'),
        ),
      ],
    );
  }
}

/// "1 message", "1,204 messages".
String _countLabel(int count) {
  final digits = count.toString();
  final grouped = digits.replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '$grouped ${count == 1 ? 'message' : 'messages'}';
}

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart' show formatBytes;
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/export_to_file.dart';

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

class _ExportShardsDialogState extends State<_ExportShardsDialog>
    with HollowDialogAction {
  Future<void> _export() async {
    int? size;
    final ok = await runDialogAction(
      () async => size = await exportToFile(
        fileName: '${exportFileStem(widget.serverName)}.hollow-shards',
        extension: 'hollow-shards',
        pickerTitle: 'Save file pieces',
        write: (path) => archive_api.exportServerShards(
            serverId: widget.serverId, outputPath: path),
      ),
      fallback: "Couldn't save the file pieces. Try again.",
    );
    if (!ok || !mounted) return;
    if (size == null) {
      // The picker was cancelled: nothing happened, so nothing to say.
      setState(() => actionRunning = false);
      return;
    }
    Navigator.of(context).pop();
    HollowToast.show(context, 'Saved ${formatBytes(size!)} of file pieces',
        type: HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.shardCount;
    return HollowDialog(
      title: 'Export file pieces',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: HollowDialogText(
        'Save the $count file ${count == 1 ? 'piece' : 'pieces'} you hold for '
        '${widget.serverName} to one file. Send it to the others who were '
        'there, and they can rebuild files without you being online.',
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _export,
          loading: actionRunning,
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

class _ImportShardsDialogState extends State<_ImportShardsDialog>
    with HollowDialogAction {
  archive_api.ShardImportResultFfi? _result;

  Future<void> _pickAndImport() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a file of pieces',
      type: FileType.custom,
      allowedExtensions: ['hollow-shards'],
    );
    final path = picked?.files.firstOrNull?.path;
    if (path == null || !mounted) return;

    late final archive_api.ShardImportResultFfi result;
    final ok = await runDialogAction(
      () async =>
          result = await archive_api.importServerShards(archivePath: path),
      fallback: "Couldn't read that file. Check it's a .hollow-shards file "
          'and try again.',
    );
    if (!ok || !mounted) return;
    setState(() {
      actionRunning = false;
      _result = result;
    });
    widget.onImported?.call();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    if (result != null) return _ImportResult(result: result);

    return HollowDialog(
      title: 'Import file pieces',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: const HollowDialogText(
        'Choose a .hollow-shards file from someone who was in the server. '
        'Pieces you are missing are added, so more files can be rebuilt.',
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _pickAndImport,
          loading: actionRunning,
          child: const Text('Choose file'),
        ),
      ],
    );
  }
}

class _ImportResult extends ConsumerWidget {
  final archive_api.ShardImportResultFfi result;

  const _ImportResult({required this.result});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(serverListProvider)[result.serverId]?.name;
    final rebuilt = result.newReconstructable;
    final headline = rebuilt == 0
        ? 'No new files can be rebuilt yet.'
        : '$rebuilt more ${rebuilt == 1 ? 'file' : 'files'} can be rebuilt '
            'now.';
    return HollowDialog(
      title: 'Pieces imported',
      showClose: true,
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(name == null || name.isEmpty
              ? headline
              : 'Added to $name. $headline'),
          const SizedBox(height: HollowSpacing.lg),
          _ResultRow(label: 'New pieces', value: result.shardsImported),
          const SizedBox(height: HollowSpacing.sm),
          _ResultRow(label: 'Already had', value: result.shardsSkipped),
        ],
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final String label;
  final int value;

  const _ResultRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        ),
        Text(
          '$value',
          style: HollowTypography.label.copyWith(
            color: hollow.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

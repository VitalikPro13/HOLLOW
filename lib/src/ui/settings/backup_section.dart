import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

/// Kept for the legacy settings dialog, which still names it.
typedef BackupCategoryView = BackupFileRow;

/// The "Backup file" row: exports the identity, friends, servers and messages
/// to one encrypted file.
class BackupFileRow extends StatefulWidget {
  const BackupFileRow({super.key});
  @override
  State<BackupFileRow> createState() => _BackupFileRowState();
}

class _BackupFileRowState extends State<BackupFileRow> {
  // Holds the button in its loading state while exportBackup runs, which
  // encrypts the identity, the messages and optionally the files and takes
  // seconds.
  bool _exporting = false;

  Future<void> _exportBackup() async {
    if (_exporting) return;
    final options = await showHollowDialog<_BackupOptions>(
      context: context,
      builder: (ctx) => const _ExportBackupDialog(),
    );
    if (options == null || !mounted) return;
    if (Platform.isAndroid || Platform.isIOS) return _exportOnPhone(options);

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export backup',
      fileName: 'hollow-backup.hollow',
      type: FileType.custom,
      allowedExtensions: ['hollow'],
    );
    if (result == null || !mounted) return;

    setState(() => _exporting = true);
    try {
      final size = await storage_api.exportBackup(
        outputPath: result,
        includeVault: options.includeVault,
        includeFiles: options.includeFiles,
        passphrase: options.passphrase,
      );
      if (!mounted) return;
      final mb = (size.toDouble() / (1024 * 1024)).toStringAsFixed(1);
      HollowToast.show(context, 'Backup exported ($mb MB)',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Export failed: $e', type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Rust writes to a path it owns and a phone's save sheet takes bytes, so the
  /// backup is staged in the data root and handed over from there.
  Future<void> _exportOnPhone(_BackupOptions options) async {
    setState(() => _exporting = true);
    final tmpPath = '$hollowDataDir/hollow-backup-export.hollow';
    try {
      await storage_api.exportBackup(
        outputPath: tmpPath,
        includeVault: options.includeVault,
        includeFiles: options.includeFiles,
        passphrase: options.passphrase,
      );
      // Read back through AtRest whether or not the writer encrypted it.
      final bytes = await AtRest.read(tmpPath);
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save backup',
        fileName: 'hollow-backup.hollow',
        bytes: bytes,
      );
      await _removeStaged(tmpPath);
      if (!mounted || savePath == null) return;
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      HollowToast.show(context, 'Backup exported ($mb MB)',
          type: HollowToastType.success);
    } catch (e) {
      await _removeStaged(tmpPath);
      if (!mounted) return;
      HollowToast.show(context, 'Export failed: $e', type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Through AtRest, so the file key row dies with the staged copy.
  static Future<void> _removeStaged(String path) async {
    try {
      await AtRest.remove(path);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      title: 'Backup file',
      subtitle:
          'Your identity, friends, servers and messages in one encrypted file',
      trailing: HollowButton.outline(
        compact: true,
        onPressed: _exporting ? null : _exportBackup,
        loading: _exporting,
        child: const Text('Export'),
      ),
    );
  }
}

class _BackupOptions {
  final String passphrase;
  final bool includeFiles;
  final bool includeVault;

  const _BackupOptions(this.passphrase, this.includeFiles, this.includeVault);
}

class _ExportBackupDialog extends StatefulWidget {
  const _ExportBackupDialog();

  @override
  State<_ExportBackupDialog> createState() => _ExportBackupDialogState();
}

class _ExportBackupDialogState extends State<_ExportBackupDialog> {
  final _passphrase = TextEditingController();
  final _repeat = TextEditingController();
  bool _includeFiles = false;
  bool _includeVault = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final pass = _passphrase.text.trim();
    if (pass.isEmpty) return;
    if (pass != _repeat.text.trim()) {
      setState(() => _error = "Passphrases don't match");
      return;
    }
    Navigator.of(context).pop(_BackupOptions(pass, _includeFiles, _includeVault));
  }

  void _clearError() {
    if (_error != null) setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Export a backup',
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText(
            'The file is encrypted with a passphrase you choose. You need it '
            'to restore the backup.',
          ),
          const SizedBox(height: HollowSpacing.sm),
          SettingsSwitchRow(
            title: 'Include downloaded files',
            value: _includeFiles,
            onChanged: (v) => setState(() => _includeFiles = v),
          ),
          SettingsSwitchRow(
            title: 'Include vault shard data',
            value: _includeVault,
            onChanged: (v) => setState(() => _includeVault = v),
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _passphrase,
            obscureText: true,
            autofocus: true,
            hintText: 'Passphrase',
            onChanged: (_) => _clearError(),
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _repeat,
            obscureText: true,
            hintText: 'Repeat the passphrase',
            errorText: _error,
            onChanged: (_) => _clearError(),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _submit,
          child: const Text('Export'),
        ),
      ],
    );
  }
}

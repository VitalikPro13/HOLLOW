import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/security_section.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Backup category: identity backup export.
class BackupCategoryView extends StatefulWidget {
  const BackupCategoryView({super.key});
  @override
  State<BackupCategoryView> createState() => _BackupCategoryViewState();
}

class _BackupCategoryViewState extends State<BackupCategoryView> {
  bool _includeVault = false;
  bool _includeFiles = false;
  // Gates the Export button while exportBackup runs, which encrypts the
  // identity, the messages and optionally the files and takes seconds.
  bool _exporting = false;

  Future<void> _exportBackup() async {
    if (_exporting) return;
    final passphrase =
        await askPassphraseDialog(context, 'Set backup passphrase', confirm: true);
    if (passphrase == null || !mounted) return;

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
        includeVault: _includeVault,
        includeFiles: _includeFiles,
        passphrase: passphrase,
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

  Widget _checkbox(HollowTheme hollow, bool value, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: value ? hollow.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: value ? hollow.accent : hollow.border,
                width: 1.5,
              ),
            ),
            child: value
                ? const Icon(LucideIcons.check, size: 12, color: Colors.white)
                : null,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Text(
            label,
            style: HollowTypography.body
                .copyWith(color: hollow.textPrimary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsCard(
            title: 'Identity Backup',
            children: [
              Text(
                'Exports your identity, profile, servers, friends, and messages.',
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: HollowSpacing.md),
              _checkbox(hollow, _includeFiles, 'Include downloaded files',
                  () => setState(() => _includeFiles = !_includeFiles)),
              const SizedBox(height: HollowSpacing.sm),
              _checkbox(hollow, _includeVault, 'Include vault shard data',
                  () => setState(() => _includeVault = !_includeVault)),
              const SizedBox(height: HollowSpacing.md),
              // Outline, not filled: "Link a device" is the section's one
              // filled primary.
              HollowButton.outline(
                onPressed: _exporting ? null : _exportBackup,
                icon: _exporting
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: hollow.textSecondary),
                      )
                    : const Icon(LucideIcons.download, size: 16),
                child: Text(_exporting ? 'Exporting…' : 'Export backup'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

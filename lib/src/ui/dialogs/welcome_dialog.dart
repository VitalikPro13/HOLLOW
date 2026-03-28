import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shows the welcome dialog on first launch (no identity).
/// Returns:
/// - `'create_new'` — user chose to create a new account
/// - `'restored_mnemonic'` — identity restored from recovery phrase
/// - `'restored_backup'` — identity imported from backup file
/// - `null` — dialog somehow dismissed without selection
Future<String?> showWelcomeDialog(BuildContext context) {
  return showHollowDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => const _WelcomeContent(),
  );
}

class _WelcomeContent extends StatefulWidget {
  const _WelcomeContent();

  @override
  State<_WelcomeContent> createState() => _WelcomeContentState();
}

enum _WelcomeView { menu, restorePhrase }

class _WelcomeContentState extends State<_WelcomeContent> {
  _WelcomeView _view = _WelcomeView.menu;
  final _phraseController = TextEditingController();
  String? _phraseError;
  bool _restoring = false;

  @override
  void dispose() {
    _phraseController.dispose();
    super.dispose();
  }

  Future<void> _onRestoreFromPhrase() async {
    final text = _phraseController.text.trim();
    final words = text.split(RegExp(r'\s+'));

    if (words.length != 24) {
      setState(() => _phraseError = 'Must be exactly 24 words (got ${words.length})');
      return;
    }

    setState(() {
      _phraseError = null;
      _restoring = true;
    });

    try {
      await identity_api.restoreIdentityFromMnemonic(phrase: text);
      if (!mounted) return;
      Navigator.of(context).pop('restored_mnemonic');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phraseError = 'Restore failed: $e';
        _restoring = false;
      });
    }
  }

  Future<void> _onRestoreFromBackup() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select Backup File',
      type: FileType.custom,
      allowedExtensions: ['hollow', 'zip'],
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final path = result.files.single.path;
    if (path == null) return;

    // Ask for passphrase.
    final passphrase = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final hollow = HollowTheme.of(ctx);
        final controller = TextEditingController();
        return AlertDialog(
          backgroundColor: hollow.surface,
          title: Text('Enter Backup Passphrase', style: HollowTypography.heading.copyWith(color: hollow.textPrimary)),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Passphrase',
              hintStyle: TextStyle(color: hollow.textSecondary),
            ),
            style: TextStyle(color: hollow.textPrimary),
            onSubmitted: (val) { if (val.isNotEmpty) Navigator.of(ctx).pop(val); },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text('Cancel', style: TextStyle(color: hollow.textSecondary)),
            ),
            TextButton(
              onPressed: () {
                final pass = controller.text.trim();
                if (pass.isNotEmpty) Navigator.of(ctx).pop(pass);
              },
              child: Text('Decrypt', style: TextStyle(color: hollow.accent)),
            ),
          ],
        );
      },
    );
    if (passphrase == null || passphrase.isEmpty || !mounted) return;

    try {
      await storage_api.importBackup(backupPath: path, passphrase: passphrase);
      if (!mounted) return;
      Navigator.of(context).pop('restored_backup');
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Import failed: $e', type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusLg);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 480,
            minWidth: 360,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.95),
                borderRadius: radius,
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 32,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(HollowSpacing.xl),
              child: _view == _WelcomeView.menu
                  ? _buildMenu(hollow)
                  : _buildRestorePhrase(hollow),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMenu(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Icon
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: hollow.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          child: Icon(
            LucideIcons.shield,
            size: 28,
            color: hollow.accent,
          ),
        ),

        const SizedBox(height: HollowSpacing.lg),

        // Title
        Text(
          'Welcome to Hollow',
          style: HollowTypography.heading.copyWith(
            color: hollow.textPrimary,
          ),
        ),

        const SizedBox(height: HollowSpacing.xs),

        // Subtitle
        Text(
          'Choose how to set up your account',
          style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
          ),
        ),

        const SizedBox(height: HollowSpacing.xl),

        // Option cards
        _OptionCard(
          icon: LucideIcons.userPlus,
          title: 'Create New Account',
          subtitle: 'Generate a new identity with a fresh recovery phrase',
          hollow: hollow,
          onTap: () => Navigator.of(context).pop('create_new'),
        ),

        const SizedBox(height: HollowSpacing.sm),

        _OptionCard(
          icon: LucideIcons.keyRound,
          title: 'Restore from Recovery Phrase',
          subtitle: 'Enter your 24-word recovery phrase',
          hollow: hollow,
          onTap: () => setState(() => _view = _WelcomeView.restorePhrase),
        ),

        const SizedBox(height: HollowSpacing.sm),

        _OptionCard(
          icon: LucideIcons.folderInput,
          title: 'Restore from Backup',
          subtitle: 'Import a .hollow backup file',
          hollow: hollow,
          onTap: _onRestoreFromBackup,
        ),
      ],
    );
  }

  Widget _buildRestorePhrase(HollowTheme hollow) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back button + title
        Row(
          children: [
            GestureDetector(
              onTap: _restoring
                  ? null
                  : () => setState(() {
                        _view = _WelcomeView.menu;
                        _phraseError = null;
                      }),
              child: Icon(
                LucideIcons.arrowLeft,
                size: 20,
                color: _restoring
                    ? hollow.textSecondary.withValues(alpha: 0.3)
                    : hollow.textSecondary,
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Restore from Recovery Phrase',
              style: HollowTypography.subheading.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),

        const SizedBox(height: HollowSpacing.lg),

        Text(
          'Enter your 24-word recovery phrase, separated by spaces.',
          style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
            fontSize: 13,
          ),
        ),

        const SizedBox(height: HollowSpacing.md),

        HollowTextField(
          controller: _phraseController,
          hintText: 'word1 word2 word3 ... word24',
          maxLines: 4,
        ),

        if (_phraseError != null) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            _phraseError!,
            style: HollowTypography.caption.copyWith(
              color: hollow.error,
              fontSize: 11,
            ),
          ),
        ],

        const SizedBox(height: HollowSpacing.lg),

        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            HollowButton.ghost(
              onPressed: _restoring
                  ? null
                  : () => setState(() {
                        _view = _WelcomeView.menu;
                        _phraseError = null;
                      }),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.filled(
              onPressed: _restoring ? null : _onRestoreFromPhrase,
              child: _restoring
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Restore'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Card-style option button for the welcome menu.
class _OptionCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final HollowTheme hollow;
  final VoidCallback onTap;

  const _OptionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.hollow,
    required this.onTap,
  });

  @override
  State<_OptionCard> createState() => _OptionCardState();
}

class _OptionCardState extends State<_OptionCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(HollowSpacing.md),
          decoration: BoxDecoration(
            color: _hovered
                ? hollow.surface.withValues(alpha: 0.8)
                : hollow.surface.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(
              color: _hovered
                  ? hollow.accent.withValues(alpha: 0.3)
                  : hollow.border,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: hollow.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                ),
                child: Icon(
                  widget.icon,
                  size: 20,
                  color: hollow.accent,
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: hollow.textSecondary.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

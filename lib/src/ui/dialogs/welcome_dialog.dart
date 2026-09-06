import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

typedef WelcomeResult = ({String action, String relayDomain});

Future<WelcomeResult?> showWelcomeDialog(BuildContext context) {
  return showHollowDialog<WelcomeResult>(
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

class _WelcomeContentState extends State<_WelcomeContent> {
  final _relayController = TextEditingController(text: kDefaultRelayDomain);
  bool _showAdvanced = false;
  // importBackup decrypts and restores the whole DB, which takes seconds.
  bool _restoring = false;

  // Profiles (issue #47). Erasing the active profile drops you here, and
  // without this the only way on is a new identity inside the folder you just
  // emptied, with no route back to Default or Portable.
  bool _showProfiles = false;
  bool _switching = false;
  late final bool _isDesktop =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  late final String _currentRoot = _isDesktop ? runningProfileRoot() : '';
  late final List<ProfileRow> _allProfiles =
      _isDesktop ? listProfileRows(readProfileRegistrySync()) : const [];

  /// The profiles that already hold an identity. A first-ever launch has none.
  late final List<ProfileRow> _otherProfiles = _allProfiles
      .where((r) =>
          !sameProfilePath(r.path, _currentRoot) && profileHasIdentity(r.path))
      .toList();

  /// What to call the profile being set up. An unlisted root falls back to its
  /// folder name rather than claiming to be Default.
  String get _currentProfileName {
    for (final row in _allProfiles) {
      if (sameProfilePath(row.path, _currentRoot)) return row.name;
    }
    final parts = _currentRoot
        .split(RegExp(r'[\\/]'))
        .where((s) => s.isNotEmpty);
    return parts.isEmpty ? _currentRoot : parts.last;
  }

  Future<void> _switchTo(ProfileRow row) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final registry = readProfileRegistrySync();
      // Pinned explicitly even for Default: the pin has to beat portable
      // auto-detection on the way back to the OS root.
      await saveProfileRegistry(registry.copyWith(activePath: row.path));
      await relaunchApp();
    } catch (e) {
      if (!mounted) return;
      setState(() => _switching = false);
      HollowToast.show(context, 'Failed to switch profile: $e',
          type: HollowToastType.error);
    }
  }

  String get _relayDomain {
    final text = _relayController.text.trim();
    return text.isEmpty ? kDefaultRelayDomain : text;
  }

  @override
  void dispose() {
    _relayController.dispose();
    super.dispose();
  }

  Future<void> _onRestoreFromBackup() async {
    if (_restoring) return;
    // Mobile does not recognise the custom `.hollow` extension, so a
    // `FileType.custom` filter hides the backup file.
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select backup file',
      type: isMobile ? FileType.any : FileType.custom,
      allowedExtensions: isMobile ? null : ['hollow'],
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final path = result.files.single.path;
    if (path == null) return;

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
            HollowButton.ghost(
              compact: true,
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancel'),
            ),
            HollowButton.filled(
              compact: true,
              onPressed: () {
                final pass = controller.text.trim();
                if (pass.isNotEmpty) Navigator.of(ctx).pop(pass);
              },
              child: const Text('Decrypt'),
            ),
          ],
        );
      },
    );
    if (passphrase == null || passphrase.isEmpty || !mounted) return;

    // A large backup takes seconds, and frozen silence on the first-run screen
    // reads as a hang.
    setState(() => _restoring = true);
    try {
      await storage_api.importBackup(backupPath: path, passphrase: passphrase);
      if (!mounted) return;
      Navigator.of(context).pop((action: 'restored_backup', relayDomain: _relayDomain));
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Import failed: $e', type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusLg);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isCompact = screenWidth < 600;
    // Never force a minimum wider than the screen.
    final minWidth = isCompact
        ? (screenWidth - HollowSpacing.xl * 2).clamp(0.0, 480.0)
        : 360.0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 480,
            minWidth: minWidth,
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
              // Scrolls when a short screen squeezes the available height.
              child: SingleChildScrollView(
                child: _buildMenu(hollow),
              ),
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

        Text(
          'Welcome to Hollow',
          style: HollowTypography.heading.copyWith(
            color: hollow.textPrimary,
          ),
        ),

        const SizedBox(height: HollowSpacing.xs),

        Text(
          'Choose how to set up your identity',
          style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
          ),
        ),

        // Which folder this is setting up, shown only once more than one
        // profile is in play. It is also the answer to where a restored backup
        // went: everything on this screen lands in the folder named here.
        if (_otherProfiles.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.sm),
          Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.folder, size: 12, color: hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.xs),
                  Flexible(
                    child: Text(
                      'Setting up the "$_currentProfileName" profile',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _currentRoot,
                style: HollowTypography.mono.copyWith(
                  color: hollow.textTertiary,
                  fontSize: 9,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],

        const SizedBox(height: HollowSpacing.xl),

        _OptionCard(
          icon: LucideIcons.userPlus,
          title: 'Create New Identity',
          subtitle: 'Generate a new identity with a fresh recovery phrase',
          hollow: hollow,
          onTap: () => Navigator.of(context).pop((action: 'create_new', relayDomain: _relayDomain)),
        ),

        const SizedBox(height: HollowSpacing.sm),

        // There is deliberately no "Restore from Recovery Phrase" here: the
        // phrase regenerates the master keypair alone, carries NO synced data,
        // and leaves a stale database on disk. Bringing a device online is
        // "Link a device" or "Restore from Backup"; the mnemonic FFI stays for
        // the in-app recovery dialogs.

        _OptionCard(
          icon: LucideIcons.smartphone,
          title: 'Link a device',
          subtitle: 'Sync from your other device with a 6-digit code',
          hollow: hollow,
          onTap: () => Navigator.of(context).pop((action: 'link_device', relayDomain: _relayDomain)),
        ),

        const SizedBox(height: HollowSpacing.sm),

        _OptionCard(
          icon: _restoring ? LucideIcons.loader : LucideIcons.folderInput,
          title: _restoring ? 'Restoring…' : 'Restore from Backup',
          subtitle: _restoring
              ? 'Decrypting and importing your backup'
              : 'Import a .hollow backup file',
          hollow: hollow,
          onTap: _onRestoreFromBackup,
        ),

        if (_otherProfiles.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          _buildProfilesSection(hollow),
        ],

        const SizedBox(height: HollowSpacing.lg),

        // Relay domain, for self-hosters.
        HollowFocusRing(
          enabled: true,
          onActivate: () => setState(() => _showAdvanced = !_showAdvanced),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          child: GestureDetector(
            onTap: () => setState(() => _showAdvanced = !_showAdvanced),
            child: Row(
              children: [
                Icon(
                  _showAdvanced ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                  size: 14,
                  color: hollow.textSecondary,
                ),
                const SizedBox(width: HollowSpacing.xs),
                Text(
                  'Advanced',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),

        if (_showAdvanced) ...[
          const SizedBox(height: HollowSpacing.sm),
          HollowTextField(
            controller: _relayController,
            hintText: kDefaultRelayDomain,
            prefixIcon: Icon(LucideIcons.server, size: 16, color: hollow.textSecondary),
            isDense: true,
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Self-hosters: enter your relay domain. Leave default for the official network.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  /// The other identities on this computer, collapsed behind one row.
  ///
  /// Desktop only: mobile data roots are sandboxed and the iOS push extension
  /// opens one fixed App Group path.
  Widget _buildProfilesSection(HollowTheme hollow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowFocusRing(
          enabled: true,
          onActivate: () => setState(() => _showProfiles = !_showProfiles),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          child: GestureDetector(
            onTap: () => setState(() => _showProfiles = !_showProfiles),
            child: Row(
              children: [
                Icon(
                  _showProfiles
                      ? LucideIcons.chevronDown
                      : LucideIcons.chevronRight,
                  size: 14,
                  color: hollow.textSecondary,
                ),
                const SizedBox(width: HollowSpacing.xs),
                Text(
                  'Use a different profile',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: HollowSpacing.xs),
                Text(
                  '(${_otherProfiles.length})',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showProfiles) ...[
          const SizedBox(height: HollowSpacing.sm),
          for (final row in _otherProfiles) ...[
            _buildProfileRow(hollow, row),
            const SizedBox(height: HollowSpacing.xs),
          ],
          Text(
            dataDirEnvOverrideActive
                ? 'HOLLOW_DATA_DIR is set. It overrides the profile selection '
                    'until Hollow is started without it.'
                : 'Switching restarts Hollow. This folder stays as it is.',
            style: HollowTypography.caption.copyWith(
              color: dataDirEnvOverrideActive
                  ? hollow.warning
                  : hollow.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProfileRow(HollowTheme hollow, ProfileRow row) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          Icon(
            row.portable ? LucideIcons.usb : LucideIcons.hardDrive,
            size: 16,
            color: hollow.textSecondary,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  row.path,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 9,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.outline(
            onPressed: _switching ? null : () => _switchTo(row),
            compact: true,
            child: const Text('Switch'),
          ),
        ],
      ),
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
      child: HollowFocusRing(
        enabled: true,
        onActivate: widget.onTap,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
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
      ),
    );
  }
}

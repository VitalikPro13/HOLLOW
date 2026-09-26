import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart'
    show formatBytes;
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/welcome_frame.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

typedef WelcomeResult = ({String action, String relayDomain});

Future<WelcomeResult?> showWelcomeDialog(BuildContext context) {
  return showHollowDialog<WelcomeResult>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => const _WelcomeContent(),
  );
}

/// A backup picked for restore, described from the file itself.
class _Backup {
  final String path;
  final String name;
  final String meta;
  const _Backup(this.path, this.name, this.meta);
}

class _WelcomeContent extends StatefulWidget {
  const _WelcomeContent();

  @override
  State<_WelcomeContent> createState() => _WelcomeContentState();
}

class _WelcomeContentState extends State<_WelcomeContent> {
  final _relayController = TextEditingController(text: kDefaultRelayDomain);
  final _passController = TextEditingController();
  bool _showAdvanced = false;
  String? _relayError;

  _Backup? _backup;
  bool _obscure = true;
  // importBackup decrypts and restores the whole DB, which takes seconds.
  bool _restoring = false;
  String? _restoreError;

  // Profiles (issue #47). Erasing the active profile drops you here, and
  // without this the only way on is a new identity inside the folder you just
  // emptied, with no route back to Default or Portable.
  bool _showProfiles = false;
  String? _switchingPath;
  late final bool _isDesktop =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  late final String _currentRoot = _isDesktop ? runningProfileRoot() : '';
  late final List<ProfileRow> _allProfiles = _isDesktop
      ? listProfileRows(readProfileRegistrySync())
      : const [];

  /// The profiles that already hold an identity. A first-ever launch has none.
  late final List<ProfileRow> _otherProfiles = _allProfiles
      .where(
        (r) =>
            !sameProfilePath(r.path, _currentRoot) &&
            profileHasIdentity(r.path),
      )
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
    if (_switchingPath != null) return;
    setState(() => _switchingPath = row.path);
    try {
      final registry = readProfileRegistrySync();
      // Pinned explicitly even for Default: the pin has to beat portable
      // auto-detection on the way back to the OS root.
      await saveProfileRegistry(registry.copyWith(activePath: row.path));
      await relaunchApp();
    } catch (e) {
      if (!mounted) return;
      setState(() => _switchingPath = null);
      HollowToast.show(
        context,
        friendlyError(
          e,
          fallback: "Hollow couldn't switch to that profile. Try again.",
        ),
        type: HollowToastType.error,
      );
    }
  }

  /// Null when what is typed is not a host, so a typo never starts the node
  /// on a relay the user did not mean.
  String? get _relayDomain {
    final text = _relayController.text.trim();
    return text.isEmpty ? kDefaultRelayDomain : normalizeRelayHost(text);
  }

  bool _relayIsUsable() {
    if (_relayDomain != null) return true;
    setState(() {
      _backup = null;
      _showAdvanced = true;
      _relayError = 'Enter a relay address, such as myrelay.duckdns.org.';
    });
    return false;
  }

  void _finish(String action) {
    if (!_relayIsUsable()) return;
    Navigator.of(context).pop((action: action, relayDomain: _relayDomain!));
  }

  @override
  void dispose() {
    _relayController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _pickBackup() async {
    if (_restoring) return;
    // Mobile does not recognise the custom `.hollow` extension, so a
    // `FileType.custom` filter hides the backup file.
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a backup',
      type: isMobile ? FileType.any : FileType.custom,
      allowedExtensions: isMobile ? null : ['hollow'],
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final picked = result.files.single;
    final path = picked.path;
    if (path == null) return;
    var meta = formatBytes(picked.size);
    // The size alone still says which file this is.
    try {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.notFound) {
        meta += ', saved ${calendarDateLabel(stat.modified)}';
      }
    } catch (_) {}
    setState(() {
      _backup = _Backup(path, picked.name, meta);
      _restoreError = null;
    });
  }

  Future<void> _restore() async {
    final backup = _backup;
    // Never trimmed: a passphrase may begin or end with a space.
    final passphrase = _passController.text;
    if (_restoring || backup == null || passphrase.isEmpty) return;
    if (!_relayIsUsable()) return;
    setState(() {
      _restoring = true;
      _restoreError = null;
    });
    try {
      await storage_api.importBackup(
        backupPath: backup.path,
        passphrase: passphrase,
      );
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop((action: 'restored_backup', relayDomain: _relayDomain!));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _restoring = false;
        _restoreError = '$e'.toLowerCase().contains('wrong passphrase')
            ? 'That passphrase does not open this backup.'
            : friendlyError(
                e,
                fallback: "Hollow couldn't open this backup. Try again.",
              );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _backup == null ? _firstRun(context) : _restoreStep(context);
  }

  Widget _firstRun(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final phone = WelcomeFrame.isPhone(context);
    final align = phone ? TextAlign.start : TextAlign.center;
    final prose = HollowTypography.body.copyWith(color: hollow.textSecondary);

    final hero = Column(
      crossAxisAlignment: phone
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (phone) const SizedBox(height: HollowSpacing.xxxl),
        ClipRRect(
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          child: Image.asset(
            'assets/hollow_logo_rounded.png',
            width: 48,
            height: 48,
            semanticLabel: 'Hollow',
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        Text(
          'Welcome to Hollow',
          textAlign: align,
          style: HollowTypography.display.copyWith(color: hollow.textPrimary),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          phone
              ? 'Your identity is made on this phone and stays with you. '
                    'There is no account and nobody to sign in to.'
              : 'Your identity is made on this device and stays with you. '
                    'There is no account and nobody to sign in to.',
          textAlign: align,
          style: prose,
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Next, Hollow shows your recovery phrase. Write it down and keep it '
          'somewhere safe.',
          textAlign: align,
          style: prose,
        ),
      ],
    );

    final rest = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowButton.filled(
          expand: true,
          touch: phone,
          onPressed: () => _finish('create_new'),
          child: const Text('Create an identity'),
        ),
        SizedBox(height: phone ? HollowSpacing.xl : HollowSpacing.xxl),
        Text(
          'Already use Hollow?',
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textSecondary,
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        // There is deliberately no "Restore from a recovery phrase" here: the
        // phrase regenerates the master keypair alone, carries NO synced data,
        // and leaves a stale database on disk. The mnemonic FFI stays for the
        // in-app recovery dialogs.
        HollowListRow(
          touch: phone,
          leading: Icon(
            LucideIcons.smartphone,
            size: 20,
            color: hollow.textSecondary,
          ),
          title: 'Link a device',
          subtitle: phone
              ? 'Enter a code from your other device'
              : 'Enter a 6-character code from your other device',
          trailing: Icon(
            LucideIcons.chevronRight,
            size: 16,
            color: hollow.textTertiary,
          ),
          onTap: () => _finish('link_device'),
        ),
        HollowListRow(
          touch: phone,
          leading: Icon(
            LucideIcons.archiveRestore,
            size: 20,
            color: hollow.textSecondary,
          ),
          title: 'Restore from a backup',
          subtitle: 'Open a .hollow file you saved earlier',
          trailing: Icon(
            LucideIcons.chevronRight,
            size: 16,
            color: hollow.textTertiary,
          ),
          onTap: _pickBackup,
        ),
        const SizedBox(height: HollowSpacing.md),
        const HollowDivider(),
        const SizedBox(height: HollowSpacing.sm),
        _footer(hollow, phone),
        if (_showAdvanced) _relaySection(hollow),
        if (_showProfiles && _otherProfiles.isNotEmpty)
          _profilesSection(hollow),
      ],
    );

    if (phone) return WelcomeFrame(body: hero, bottom: rest);
    return WelcomeFrame(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          hero,
          const SizedBox(height: HollowSpacing.xl),
          rest,
        ],
      ),
    );
  }

  Widget _footer(HollowTheme hollow, bool phone) {
    final domain = _relayDomain ?? _relayController.text.trim();
    // The button cannot ellipsize its label, and a domain can be any length.
    final shown = domain.length > 32 ? '${domain.substring(0, 31)}…' : domain;
    final relay = HollowButton.ghost(
      compact: !phone,
      touch: phone,
      semanticLabel: 'Change the relay, $domain',
      icon: const Icon(LucideIcons.server, size: 14),
      onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
      child: Text(shown),
    );
    // Other profiles are desktop only: mobile data roots are sandboxed and the
    // iOS push extension opens one fixed App Group path.
    if (_otherProfiles.isEmpty) {
      return Align(
        alignment: phone ? Alignment.center : Alignment.centerRight,
        child: relay,
      );
    }
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.xs,
      children: [
        HollowButton.ghost(
          compact: true,
          icon: const Icon(LucideIcons.folder, size: 14),
          onPressed: () => setState(() => _showProfiles = !_showProfiles),
          child: Text('Other profiles (${_otherProfiles.length})'),
        ),
        relay,
      ],
    );
  }

  Widget _relaySection(HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Relay address',
            style: HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          HollowTextField(
            controller: _relayController,
            hintText: kDefaultRelayDomain,
            errorText: _relayError,
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() => _relayError = null),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Leave it as it is for the official network. If you run your own '
            'relay, enter its domain.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _profilesSection(HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Also the answer to where a restored backup went: everything on
          // this screen lands in the folder named here.
          Text(
            'This window is setting up the "$_currentProfileName" profile.',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
          for (final row in _otherProfiles)
            HollowListRow(
              leading: Icon(
                row.portable ? LucideIcons.usb : LucideIcons.hardDrive,
                size: 20,
                color: hollow.textSecondary,
              ),
              title: row.name,
              subtitle: row.path,
              trailing: HollowButton.outline(
                compact: true,
                loading: _switchingPath == row.path,
                onPressed: _switchingPath == null ? () => _switchTo(row) : null,
                child: const Text('Switch'),
              ),
            ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            dataDirEnvOverrideActive
                ? 'HOLLOW_DATA_DIR is set. It overrides the profile selection '
                      'until Hollow is started without it.'
                : 'Switching restarts Hollow. This folder stays as it is.',
            style: HollowTypography.caption.copyWith(
              color: dataDirEnvOverrideActive
                  ? hollow.warning
                  : hollow.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _restoreStep(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final phone = WelcomeFrame.isPhone(context);
    final backup = _backup!;

    final file = DecoratedBox(
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.md),
        child: Row(
          children: [
            Icon(LucideIcons.file, size: 20, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    backup.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.label.copyWith(
                      color: hollow.textPrimary,
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.xxs),
                  Text(
                    backup.meta,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              compact: !phone,
              touch: phone,
              onPressed: _restoring ? null : _pickBackup,
              child: const Text('Choose another'),
            ),
          ],
        ),
      ),
    );

    final canRestore = _passController.text.isNotEmpty;
    return WelcomeFrame(
      title: 'Restore from a backup',
      backEnabled: !_restoring,
      onBack: () => setState(() {
        _backup = null;
        _restoreError = null;
        _passController.clear();
      }),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          file,
          const SizedBox(height: HollowSpacing.xl),
          Text(
            'Backup passphrase',
            style: HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          // The same raw text goes in from Enter and from the button.
          IgnorePointer(
            ignoring: _restoring,
            child: ExcludeFocus(
              excluding: _restoring,
              child: HollowTextField(
                controller: _passController,
                obscureText: _obscure,
                autofocus: true,
                errorText: _restoreError,
                onChanged: (_) => setState(() => _restoreError = null),
                onSubmitted: (_) => _restore(),
                trailing: Padding(
                  padding: const EdgeInsets.only(right: HollowSpacing.xs),
                  child: HollowIconButton(
                    icon: _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
                    label: _obscure ? 'Show passphrase' : 'Hide passphrase',
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ),
          ),
          if (_restoreError == null) ...[
            const SizedBox(height: HollowSpacing.sm),
            Text(
              _restoring
                  ? 'Decrypting and importing. This can take a minute.'
                  : 'The one you chose when you made the backup.',
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ],
      ),
      bottom: WelcomeActions(
        children: [
          HollowButton.filled(
            expand: phone,
            touch: phone,
            loading: _restoring,
            onPressed: canRestore ? _restore : null,
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }
}

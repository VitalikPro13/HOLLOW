import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/core/single_instance_lock.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/wipe.dart' as wipe_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Profiles rows of Settings > Files & Storage (issue #47): switch between
/// or erase separate identities, each in its own data folder. Desktop-only,
/// because mobile data roots are sandboxed and the iOS push extension opens
/// one fixed App Group DB path.
///
/// Switching pins the chosen root in the registry and restarts Hollow; erasing
/// the running profile goes through the pending-wipe marker, because
/// in-process DB deletes fail on Windows while the node holds SQLCipher
/// handles.
class ProfileLocationsCard extends StatefulWidget {
  const ProfileLocationsCard({super.key});

  @override
  State<ProfileLocationsCard> createState() => _ProfileLocationsCardState();
}

class _ProfileLocationsCardState extends State<ProfileLocationsCard> {
  ProfileRegistry _registry = const ProfileRegistry();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _registry = readProfileRegistrySync();
  }

  String get _runningRoot => runningProfileRoot();

  bool get _envOverrideActive => dataDirEnvOverrideActive;

  List<ProfileRow> _buildRows() => listProfileRows(_registry);

  /// Empty folders and recognizable Hollow data roots qualify; anything else is
  /// refused, so we never onboard into (or erase) a folder of unrelated files.
  bool _isEmptyOrHollowData(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return true; // will be created
    if (dir.listSync(followLinks: false).isEmpty) return true;
    const markers = [
      'identity.key',
      'identity.device',
      'messages.db',
      'hollow_debug.log',
    ];
    final sep = Platform.pathSeparator;
    return markers.any((m) => File('$path$sep$m').existsSync());
  }

  /// True if another live Hollow instance holds this profile's lock.
  bool _profileInUse(String path) =>
      SingleInstanceLock.heldByAnotherProcess(SingleInstanceLock.fileIn(path));

  Future<void> _saveRegistry(ProfileRegistry next) async {
    await saveProfileRegistry(next);
    if (mounted) setState(() => _registry = next);
  }

  Future<void> _confirmSwitch(ProfileRow row) async {
    final proceed = await showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) => HollowDialog(
        title: 'Switch profile',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HollowDialogText('Hollow will restart using "${row.name}":'),
            const SizedBox(height: HollowSpacing.xs),
            Text(row.path, style: HollowTypography.monoSmall),
            const SizedBox(height: HollowSpacing.sm),
            const HollowDialogText(
              'If the folder is empty, first-time setup will create a new '
              'identity there. Your current profile stays on disk untouched.',
            ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Switch and restart'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // Pin explicitly even for the Default row: the pin must beat portable
      // auto-detection on the way back to the OS root.
      await saveProfileRegistry(_registry.copyWith(activePath: row.path));
      await relaunchApp();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't switch the profile. Try again."),
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _addProfile() async {
    final picked = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose a profile folder');
    if (picked == null || picked.isEmpty || !mounted) return;

    final portable = portableCandidatePath();
    if (portable != null && sameProfilePath(picked, portable)) {
      // The folder may have appeared after this card was last built.
      setState(() {});
      HollowToast.show(
          context, "That's the portable folder. Use its row in the list.",
          type: HollowToastType.info);
      return;
    }
    if (_buildRows().any((r) => sameProfilePath(r.path, picked))) {
      HollowToast.show(context, 'That folder is already in the list',
          type: HollowToastType.info);
      return;
    }
    if (!_isEmptyOrHollowData(picked)) {
      HollowToast.show(
          context,
          'Pick an empty folder for a new identity, or an existing '
          'Hollow data folder',
          type: HollowToastType.error);
      return;
    }

    final baseName = picked
        .split(Platform.pathSeparator)
        .where((s) => s.isNotEmpty)
        .lastOrNull;
    await promptForName(
      context: context,
      title: 'Add a profile',
      confirmLabel: 'Add',
      hintText: 'Profile name, like Artist or Personal',
      initial: baseName ?? 'New profile',
      maxLength: 32,
      onSubmit: (name) => _saveRegistry(_registry.copyWith(custom: [
        ..._registry.custom,
        HollowProfile(name: name, path: picked),
      ])),
    );
  }

  Future<void> _renameProfile(ProfileRow row) async {
    await promptForName(
      context: context,
      title: 'Rename profile',
      confirmLabel: 'Rename',
      hintText: 'Profile name',
      initial: row.name,
      maxLength: 32,
      onSubmit: (name) => _saveRegistry(_registry.copyWith(
        custom: [
          for (final c in _registry.custom)
            sameProfilePath(c.path, row.path)
                ? HollowProfile(name: name, path: c.path)
                : c,
        ],
      )),
    );
  }

  Future<void> _removeProfile(ProfileRow row) async {
    try {
      await _saveRegistry(_registry.copyWith(
        custom: [
          for (final c in _registry.custom)
            if (!sameProfilePath(c.path, row.path)) c,
        ],
      ));
      if (mounted) {
        HollowToast.show(context, 'Removed from the list, data kept on disk',
            type: HollowToastType.info);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't remove it from the list. Try again."),
            type: HollowToastType.error);
      }
    }
  }

  /// What this profile's own identity file demands before it may be deleted.
  ///
  /// Erasing an offline profile is a recursive delete of somebody's identity,
  /// so without this anyone at an unlocked Hollow could wipe a DIFFERENT,
  /// password-protected profile. The check reads that profile's `identity.key`
  /// directly, because the running process has only ever unlocked its own.
  Future<_EraseChallenge> _eraseChallengeFor(ProfileRow row) async {
    try {
      final status =
          await identity_api.identityProtectionStatusAt(dataDir: row.path);
      if (!status.isEncrypted) return _EraseChallenge.none;
      if (status.hasPassword) return _EraseChallenge.password;
      // Keychain-only protection unlocks silently at launch, so a machine that
      // can still unwrap the file has proved as much as a prompt would. One
      // that cannot falls back to typing the name.
      final unwrappable =
          await identity_api.verifyIdentityPasswordAt(dataDir: row.path);
      return unwrappable ? _EraseChallenge.none : _EraseChallenge.name;
    } catch (_) {
      // An identity file we cannot read is one we cannot clear: fail closed.
      return _EraseChallenge.name;
    }
  }

  Future<void> _confirmErase(ProfileRow row) async {
    final isRunning = sameProfilePath(row.path, _runningRoot);

    setState(() => _busy = true);
    final challenge = await _eraseChallengeFor(row);
    if (!mounted) return;
    setState(() => _busy = false);

    final proceed = await showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) => _EraseProfileDialog(
        name: row.name,
        path: row.path,
        isRunning: isRunning,
        challenge: challenge,
      ),
    );
    if (proceed != true || !mounted) return;

    if (isRunning) {
      // The same routine the Security tab's Danger zone runs, so erasing the
      // running profile and destroying this device's data are one code path.
      // The live node holds open SQLCipher handles and in-process deletes fail
      // on Windows, so it leaves a marker the next launch finishes.
      setState(() => _busy = true);
      try {
        await wipe_api.destroyLocal();
        await clearLocalSecretsAfterDestroy();
        await relaunchApp();
      } catch (e) {
        if (mounted) {
          setState(() => _busy = false);
          HollowToast.show(
              context,
              friendlyError(e,
                  fallback: "Couldn't erase the profile. Try again."),
              type: HollowToastType.error);
        }
      }
      return;
    }

    // No open handles, so this deletes directly. Still guarded: never touch a
    // folder another instance is using or that does not look like Hollow data.
    if (_profileInUse(row.path)) {
      HollowToast.show(
          context, 'That profile is open in another Hollow instance',
          type: HollowToastType.error);
      return;
    }
    if (!_isEmptyOrHollowData(row.path)) {
      HollowToast.show(
          context, "That folder doesn't look like Hollow data, so it stays.",
          type: HollowToastType.error);
      return;
    }
    setState(() => _busy = true);
    try {
      final dir = Directory(row.path);
      if (dir.existsSync()) {
        await for (final entity in dir.list(followLinks: false)) {
          final name = entity.path.split(Platform.pathSeparator).last;
          // Same keep-list as Rust's perform_pending_wipe: the registry is
          // app-level config and stale locks are harmless.
          if (name == 'profiles.json' || name.endsWith('.lock')) continue;
          await entity.delete(recursive: true);
        }
      }
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(context, 'Profile data erased',
            type: HollowToastType.info);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't erase the profile. Try again."),
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _buildRows();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          title: 'Profiles',
          subtitle: 'Separate identities, each in its own folder. Switching '
              'restarts Hollow.',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A switch or erase is running; every profile action waits.
              if (_busy) ...[
                const HollowSpinner(),
                const SizedBox(width: HollowSpacing.sm),
              ],
              HollowButton.ghost(
                compact: true,
                onPressed: _busy ? null : _addProfile,
                child: const Text('Add a profile'),
              ),
            ],
          ),
        ),
        if (_envOverrideActive)
          const SettingsNote(
              'HOLLOW_DATA_DIR is set, so it picks the folder until Hollow '
              'starts without it.'),
        Padding(
          padding: const EdgeInsets.only(left: HollowSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [for (final row in rows) _buildRow(row)],
          ),
        ),
      ],
    );
  }

  Widget _buildRow(ProfileRow row) {
    final hollow = HollowTheme.of(context);
    final active = sameProfilePath(row.path, _runningRoot);
    final exists = Directory(row.path).existsSync();
    final menu = [
      if (!row.builtin)
        HollowMenuItem(
          icon: LucideIcons.pencil,
          label: 'Rename',
          enabled: !_busy,
          onTap: () => _renameProfile(row),
        ),
      if (!row.builtin && !active)
        HollowMenuItem(
          icon: LucideIcons.listX,
          label: 'Remove from the list',
          enabled: !_busy,
          onTap: () => _removeProfile(row),
        ),
      if (exists)
        HollowMenuItem(
          icon: LucideIcons.trash2,
          label: 'Erase',
          isDanger: true,
          enabled: !_busy,
          onTap: () => _confirmErase(row),
        ),
    ];

    return SettingsRow(
      title: row.name,
      titleTrailing: active ? const HollowBadge('In use') : null,
      subtitleWidget: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            row.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                HollowTypography.monoSmall.copyWith(color: hollow.textSecondary),
          ),
          if (!exists)
            const Text('Not created yet. Switching starts a new identity here'),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!active)
            HollowButton.outline(
              compact: true,
              onPressed: _busy ? null : () => _confirmSwitch(row),
              child: const Text('Switch'),
            ),
          if (menu.isNotEmpty) ...[
            const SizedBox(width: HollowSpacing.xs),
            Builder(
              builder: (buttonContext) => HollowIconButton(
                icon: LucideIcons.ellipsis,
                label: 'More for ${row.name}',
                tooltip: 'More',
                onPressed: () => showHollowMenu(
                  context: buttonContext,
                  anchor: overlayAnchorOf(
                    buttonContext,
                    localOffset: Offset(buttonContext.size?.width ?? 0,
                        (buttonContext.size?.height ?? 0) + HollowSpacing.xs),
                  ),
                  alignEnd: true,
                  builder: (_, _) => menu,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What a profile asks for before it may be erased.
enum _EraseChallenge {
  /// Unprotected, or protected in a way this machine already satisfies.
  none,

  /// Password-protected: the password must actually unwrap its identity file.
  password,

  /// Protected but not unwrappable here, so the profile name is typed instead.
  /// Not authentication, just a wall nobody clears by accident.
  name,
}

/// The erase confirmation. Stateful because the challenge is verified INSIDE
/// the dialog, so a wrong password reports itself in the field rather than
/// closing the dialog and firing a toast.
class _EraseProfileDialog extends StatefulWidget {
  final String name;
  final String path;
  final bool isRunning;
  final _EraseChallenge challenge;

  const _EraseProfileDialog({
    required this.name,
    required this.path,
    required this.isRunning,
    required this.challenge,
  });

  @override
  State<_EraseProfileDialog> createState() => _EraseProfileDialogState();
}

class _EraseProfileDialogState extends State<_EraseProfileDialog> {
  final _controller = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _needsChallenge => widget.challenge != _EraseChallenge.none;

  Future<void> _confirm() async {
    if (_checking) return;
    final navigator = Navigator.of(context);
    if (!_needsChallenge) {
      navigator.pop(true);
      return;
    }

    final typed = _controller.text.trim();
    if (typed.isEmpty) return;

    if (widget.challenge == _EraseChallenge.name) {
      if (typed.toLowerCase() != widget.name.trim().toLowerCase()) {
        setState(() => _error = 'That is not this profile\'s name.');
        return;
      }
      navigator.pop(true);
      return;
    }

    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final ok = await identity_api.verifyIdentityPasswordAt(
        dataDir: widget.path,
        password: typed,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _checking = false;
          _error = "That password isn't right.";
        });
        return;
      }
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = friendlyError(e,
            fallback: "Couldn't check the password. Try again.");
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final canConfirm = !_checking &&
        (!_needsChallenge || _controller.text.trim().isNotEmpty);

    return HollowDialog(
      title: 'Erase profile',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(
            'This permanently deletes the identity key, message history, '
            'and downloaded files of "${widget.name}":',
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(widget.path, style: HollowTypography.monoSmall),
          const SizedBox(height: HollowSpacing.sm),
          HollowDialogText(
            'Without its 24-word recovery phrase this identity cannot be '
            'restored.${widget.isRunning ? ' Hollow will restart to finish and '
                'open first-time setup.' : ''}',
          ),
          if (_needsChallenge) ...[
            const SizedBox(height: HollowSpacing.md),
            HollowDialogText(
              widget.challenge == _EraseChallenge.password
                  ? 'This profile is password-protected. Enter its password to '
                      'erase it.'
                  : 'This profile is protected and cannot be unlocked on this '
                      'computer. Type its name to erase it anyway.',
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowTextField(
              controller: _controller,
              autofocus: true,
              obscureText: widget.challenge == _EraseChallenge.password,
              hintText: widget.challenge == _EraseChallenge.password
                  ? 'Profile password'
                  : widget.name,
              errorText: _error,
              onChanged: (_) => setState(() => _error = null),
              onSubmitted: (_) => _confirm(),
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _checking ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          onPressed: canConfirm ? _confirm : null,
          loading: _checking,
          child: Text(widget.isRunning ? 'Erase and restart' : 'Erase profile'),
        ),
      ],
    );
  }
}

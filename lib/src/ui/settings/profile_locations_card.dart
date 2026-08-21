import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Profiles block (issue #47) — switch between / erase separate identities,
/// each living in its own data folder. Rendered at the bottom of the desktop
/// Settings > Profile category. Desktop-only: mobile data roots are sandboxed
/// and the iOS push extension opens one fixed App Group DB path.
///
/// Rows: the OS-default root, the portable `hollow_data` folder next to the
/// exe (when present), and user-added folders from profiles.json. Switching
/// pins the chosen root in the registry and restarts Hollow; erasing the
/// running profile reuses the pending-wipe flow (marker + restart — in-process
/// DB deletes fail on Windows while the node holds SQLCipher handles).
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

  IconData _iconFor(ProfileRow row) {
    if (row.portable) return LucideIcons.usb;
    return row.builtin ? LucideIcons.hardDrive : LucideIcons.folder;
  }

  // ── Shared helpers ─────────────────────────────────────────────────

  /// Empty folders and recognizable Hollow data roots qualify; anything else
  /// (a Documents folder, a project dir) is refused so we never onboard into —
  /// or worse, erase — a folder full of unrelated files.
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

  /// True if another live Hollow instance holds this profile's lock (same
  /// PID + process-name check as the boot single-instance guard).
  bool _profileInUse(String path) {
    try {
      final lock = File('$path${Platform.pathSeparator}hollow.lock');
      if (!lock.existsSync()) return false;
      final lockPid = int.tryParse(lock.readAsStringSync().trim());
      if (lockPid == null || lockPid == pid) return false;
      if (Platform.isWindows) {
        final r = Process.runSync('tasklist', ['/FI', 'PID eq $lockPid', '/NH']);
        final out = r.stdout.toString().toLowerCase();
        return out.contains('$lockPid') && out.contains('hollow');
      }
      final r = Process.runSync('ps', ['-p', '$lockPid', '-o', 'comm=']);
      return r.exitCode == 0 &&
          r.stdout.toString().toLowerCase().contains('hollow');
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveRegistry(ProfileRegistry next) async {
    await saveProfileRegistry(next);
    if (mounted) setState(() => _registry = next);
  }

  // ── Switch ─────────────────────────────────────────────────────────

  Future<void> _confirmSwitch(ProfileRow row) async {
    final proceed = await showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) => HollowDialog(
        title: 'Switch profile',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Hollow will restart using "${row.name}":',
              style: HollowTypography.body,
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(row.path, style: HollowTypography.mono.copyWith(fontSize: 11)),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              'If the folder is empty, first-time setup will create a new '
              'identity there. Your current profile stays on disk untouched.',
              style: HollowTypography.bodySmall,
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
            child: const Text('Switch & restart'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // Pin explicitly even for the Default row — the pin must beat the
      // portable auto-detection (an existing hollow_data folder) on the way
      // back to the OS root.
      await saveProfileRegistry(_registry.copyWith(activePath: row.path));
      await relaunchApp();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(context, 'Failed to switch profile: $e',
            type: HollowToastType.error);
      }
    }
  }

  // ── Add / rename / remove ──────────────────────────────────────────

  Future<String?> _promptName({required String initial}) async {
    final controller = TextEditingController(text: initial);
    final name = await showHollowDialog<String>(
      context: context,
      builder: (dialogContext) => HollowDialog(
        title: 'Profile name',
        content: HollowTextField(
          controller: controller,
          hintText: 'e.g. Artist, Personal',
          autofocus: true,
          maxLength: 32,
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return (name == null || name.isEmpty) ? null : name;
  }

  Future<void> _addProfile() async {
    final picked = await FilePicker.platform
        .getDirectoryPath(dialogTitle: 'Choose a profile folder');
    if (picked == null || picked.isEmpty || !mounted) return;

    final portable = portableCandidatePath();
    if (portable != null && sameProfilePath(picked, portable)) {
      // Refresh so the row is visibly there even if the folder appeared
      // after this card was last built.
      setState(() {});
      HollowToast.show(
          context, 'That is the portable folder: use its row in the list',
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
    final name = await _promptName(initial: baseName ?? 'New profile');
    if (name == null || !mounted) return;

    try {
      await _saveRegistry(_registry.copyWith(custom: [
        ..._registry.custom,
        HollowProfile(name: name, path: picked),
      ]));
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to save profile list: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _renameProfile(ProfileRow row) async {
    final name = await _promptName(initial: row.name);
    if (name == null || !mounted) return;
    try {
      await _saveRegistry(_registry.copyWith(
        custom: [
          for (final c in _registry.custom)
            sameProfilePath(c.path, row.path)
                ? HollowProfile(name: name, path: c.path)
                : c,
        ],
      ));
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to rename: $e',
            type: HollowToastType.error);
      }
    }
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
        HollowToast.show(context, 'Failed to remove: $e',
            type: HollowToastType.error);
      }
    }
  }

  // ── Erase ──────────────────────────────────────────────────────────

  /// What this profile's own identity file demands before it may be deleted.
  ///
  /// Erasing an offline profile is a plain recursive delete of somebody's
  /// identity, and until now it asked for nothing: anyone at an unlocked
  /// Hollow could wipe a DIFFERENT, password-protected profile without ever
  /// knowing its password. The check reads that profile's `identity.key`
  /// directly, because the running process has only ever unlocked its own.
  Future<_EraseChallenge> _eraseChallengeFor(ProfileRow row) async {
    try {
      final status =
          await identity_api.identityProtectionStatusAt(dataDir: row.path);
      if (!status.isEncrypted) return _EraseChallenge.none;
      if (status.hasPassword) return _EraseChallenge.password;
      // Keychain-only protection unlocks silently at launch on this machine,
      // so a machine that can still unwrap the file has already proved as much
      // as a prompt would. One that cannot (a folder copied from another
      // computer) falls back to typing the name.
      final unwrappable =
          await identity_api.verifyIdentityPasswordAt(dataDir: row.path);
      return unwrappable ? _EraseChallenge.none : _EraseChallenge.name;
    } catch (_) {
      // An identity file we cannot read is one we cannot clear, so fail closed
      // rather than open.
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
      // The live node holds open SQLCipher handles — in-process deletes fail
      // on Windows. Reuse the revocation self-nuke mechanic: mark a pending
      // wipe and relaunch; the next launch wipes pre-node-start.
      setState(() => _busy = true);
      try {
        await storage_api.stashPendingWipe();
        await relaunchApp();
      } catch (e) {
        if (mounted) {
          setState(() => _busy = false);
          HollowToast.show(context, 'Failed to erase: $e',
              type: HollowToastType.error);
        }
      }
      return;
    }

    // Offline profile — no open handles, delete directly. Still guarded:
    // never touch a folder another instance is using or that doesn't look
    // like Hollow data.
    if (_profileInUse(row.path)) {
      HollowToast.show(
          context, 'That profile is open in another Hollow instance',
          type: HollowToastType.error);
      return;
    }
    if (!_isEmptyOrHollowData(row.path)) {
      HollowToast.show(
          context, 'That folder does not look like Hollow data. Not erasing',
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
          // app-level config (only present when this row is the default
          // root), and stale locks are harmless.
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
        HollowToast.show(context, 'Erase failed: $e',
            type: HollowToastType.error);
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final rows = _buildRows();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
                child: SettingsSectionLabel(label: 'PROFILES ON THIS COMPUTER')),
            if (_busy)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: hollow.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Each profile is a separate identity stored in its own folder. '
          'Switching restarts Hollow; the profile you leave stays on disk. '
          'Identity protection via the OS keychain holds only one '
          'identity per computer. Use password protection for additional '
          'profiles.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 10,
            height: 1.4,
          ),
        ),
        if (_envOverrideActive) ...[
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'HOLLOW_DATA_DIR is set. It overrides the profile selection '
            'until Hollow is started without it.',
            style: HollowTypography.caption.copyWith(
              color: hollow.warning,
              fontSize: 10,
            ),
          ),
        ],
        const SizedBox(height: HollowSpacing.md),
        for (final row in rows) ...[
          _buildRow(hollow, row),
          const SizedBox(height: HollowSpacing.xs),
        ],
        const SizedBox(height: HollowSpacing.xs),
        HollowButton.outline(
          onPressed: _busy ? null : _addProfile,
          icon: const Icon(LucideIcons.folderPlus, size: 14),
          compact: true,
          child: const Text('Add profile folder'),
        ),
      ],
    );
  }

  Widget _buildRow(HollowTheme hollow, ProfileRow row) {
    final active = sameProfilePath(row.path, _runningRoot);
    final exists = Directory(row.path).existsSync();

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: active ? hollow.accent : hollow.border),
      ),
      child: Row(
        children: [
          Icon(_iconFor(row), size: 16,
              color: active ? hollow.accentText : hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.name,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: HollowSpacing.xs, vertical: 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(hollow.radiusSm),
                          border: Border.all(color: hollow.accent),
                        ),
                        child: Text(
                          'ACTIVE',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.accentText,
                            fontWeight: FontWeight.w700,
                            fontSize: 8,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ],
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
                if (!exists)
                  Text(
                    'Not created yet. Switching starts a new identity here',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 9,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (!active)
            HollowButton.outline(
              onPressed: _busy ? null : () => _confirmSwitch(row),
              compact: true,
              child: const Text('Switch'),
            ),
          if (!row.builtin) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowButton.ghost(
              onPressed: _busy ? null : () => _renameProfile(row),
              compact: true,
              child: const Text('Rename'),
            ),
            if (!active) ...[
              const SizedBox(width: HollowSpacing.xs),
              HollowButton.ghost(
                onPressed: _busy ? null : () => _removeProfile(row),
                compact: true,
                child: const Text('Remove'),
              ),
            ],
          ],
          if (exists) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowButton.danger(
              onPressed: _busy ? null : () => _confirmErase(row),
              compact: true,
              child: const Text('Erase'),
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

  /// Protected but not unwrappable here. There is no secret to check against,
  /// so the profile name is typed instead. Not authentication, just a wall
  /// high enough that nobody clears it by accident.
  name,
}

/// The erase confirmation. Stateful because the challenge is verified INSIDE
/// the dialog: a wrong password reports itself in the field the user is
/// looking at, instead of closing the dialog and firing a toast.
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
          _error = 'Wrong password.';
        });
        return;
      }
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = 'Could not check the password: $e';
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
          Text(
            'This permanently deletes the identity key, message history, '
            'and downloaded files of "${widget.name}":',
            style: HollowTypography.body,
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(widget.path,
              style: HollowTypography.mono.copyWith(fontSize: 11)),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Without its 24-word recovery phrase this identity cannot be '
            'restored.${widget.isRunning ? ' Hollow will restart to finish and '
                'open first-time setup.' : ''}',
            style: HollowTypography.bodySmall,
          ),
          if (_needsChallenge) ...[
            const SizedBox(height: HollowSpacing.md),
            Text(
              widget.challenge == _EraseChallenge.password
                  ? 'This profile is password-protected. Enter its password to '
                      'erase it.'
                  : 'This profile is protected and cannot be unlocked on this '
                      'computer. Type its name to erase it anyway.',
              style: HollowTypography.bodySmall,
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowTextField(
              controller: _controller,
              autofocus: true,
              isDense: true,
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
          child: Text(_checking
              ? 'Checking...'
              : (widget.isRunning ? 'Erase & restart' : 'Erase profile')),
        ),
      ],
    );
  }
}

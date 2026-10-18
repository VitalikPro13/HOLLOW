import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/protection_prompt.dart'
    show kProtectionOfferDueKey;
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shell/identity_unlock_dialogs.dart';

/// True when unlock failed because a keychain-protected identity's key is not
/// in this computer's keystore. Rust touched nothing, so the same files open
/// again once the key is back.
bool isKeychainKeyMissing(Object error) =>
    error.toString().contains('keychain_key_missing');

const String kHardwareKeyBusyTitle = "Hollow couldn't unlock just now";
const String kHardwareKeyBusyBody =
    "Your phone's secure storage didn't respond this time. Nothing has "
    "changed, and this try doesn't count as a wrong one.";
const String kHardwareKeyBusyNext =
    'Try again in a moment. If it keeps happening, restart your phone. Your '
    'recovery phrase always gets you back in.';
const String kHardwareKeyStillBusy =
    "It still didn't respond. Nothing has changed.";

/// What the key-missing screen lets the person do next.
enum KeyMissingChoice { phrase, backup }

/// The launch screen for an identity whose keychain key is gone. Nothing is
/// deleted or replaced unless the person picks a restore: Try again opens the
/// same files once the key is back. True once the identity is open.
Future<bool> showKeyMissingScreen(BuildContext context) async {
  while (true) {
    if (!context.mounted) return false;
    final choice = await showHollowDialog<Object>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const KeyMissingDialog(),
    );
    if (choice == true) return true;
    if (!context.mounted) return false;
    final bool restored;
    if (choice == KeyMissingChoice.phrase) {
      restored = await _restoreWithPhrase(context);
    } else if (choice == KeyMissingChoice.backup) {
      restored = await _restoreFromBackup(context);
    } else {
      restored = false;
    }
    if (restored) return true;
  }
}

/// Where the key was kept, as the person knows it.
String _keyStore() {
  if (Platform.isMacOS) return "your Mac's keychain";
  if (Platform.isWindows) return 'Windows Credential Manager';
  return 'the computer that set Hollow up';
}

String _likelyCause() {
  if (Platform.isWindows) {
    return 'This can happen after an administrator resets your Windows '
        'password, after Windows is reinstalled, or when this Hollow folder '
        'came from another computer or account.';
  }
  if (Platform.isMacOS) {
    return "This can happen when your Mac's login password was reset without "
        'the old one, when your keychain is locked, or when this Hollow folder '
        'came from another Mac or account.';
  }
  return 'This happens when this Hollow folder came from another computer, '
      'which keeps the key.';
}

/// Pops `true` once Try again opened the identity, or a [KeyMissingChoice].
class KeyMissingDialog extends StatefulWidget {
  const KeyMissingDialog({super.key});

  @override
  State<KeyMissingDialog> createState() => _KeyMissingDialogState();
}

class _KeyMissingDialogState extends State<KeyMissingDialog>
    with HollowDialogAction {
  Future<void> _retry() async {
    final ok = await runDialogAction(() async {
      try {
        await identity_api.unlockIdentity();
      } catch (e) {
        if (isKeychainKeyMissing(e)) {
          throw const FriendlyException(
              "The key still isn't there, so nothing has changed.");
        }
        rethrow;
      }
    });
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: "Hollow can't open your identity",
      width: 460,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(
              'Your identity on this computer is locked with a key that '
              "${_keyStore()} keeps. Hollow can't get that key right now. "
              'Nothing has been deleted.'),
          const SizedBox(height: HollowSpacing.md),
          HollowDialogText(_likelyCause()),
          const SizedBox(height: HollowSpacing.md),
          const HollowDialogText(
              'If the key comes back, for example when you sign in to the '
              'account you set Hollow up with, Hollow opens as before. '
              'Otherwise your recovery phrase or a backup file brings your '
              'identity back on this computer.'),
        ],
      ),
      leadingActions: [
        HollowButton.ghost(
          onPressed: actionRunning
              ? null
              : () => Navigator.of(context).pop(KeyMissingChoice.backup),
          child: const Text('Restore a backup'),
        ),
      ],
      actions: [
        HollowButton.outline(
          onPressed: actionRunning
              ? null
              : () => Navigator.of(context).pop(KeyMissingChoice.phrase),
          child: const Text('Use recovery phrase'),
        ),
        HollowButton.filled(
          onPressed: _retry,
          loading: actionRunning,
          child: const Text('Try again'),
        ),
      ],
    );
  }
}

/// The phone's secure hardware did not answer an unlock this once. Nothing was
/// counted or changed, so Try again comes first; the recovery phrase stays the
/// way out if it never answers. Pops `true` once [retry] opened the identity,
/// [KeyMissingChoice.phrase], or the error of a retry that failed some other way.
class HardwareKeyBusyDialog extends StatefulWidget {
  final Future<void> Function() retry;

  const HardwareKeyBusyDialog({super.key, required this.retry});

  @override
  State<HardwareKeyBusyDialog> createState() => _HardwareKeyBusyDialogState();
}

class _HardwareKeyBusyDialogState extends State<HardwareKeyBusyDialog>
    with HollowDialogAction {
  Future<void> _retry() async {
    Object? other;
    final ok = await runDialogAction(() async {
      try {
        await widget.retry();
      } catch (e) {
        if (isHardwareKeyBusy(e)) {
          throw const FriendlyException(kHardwareKeyStillBusy);
        }
        other = e;
      }
    });
    if (!mounted) return;
    if (other != null) {
      Navigator.of(context).pop(other);
    } else if (ok) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: kHardwareKeyBusyTitle,
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(kHardwareKeyBusyBody),
          SizedBox(height: HollowSpacing.md),
          HollowDialogText(kHardwareKeyBusyNext),
        ],
      ),
      actions: [
        HollowButton.outline(
          onPressed: actionRunning
              ? null
              : () => Navigator.of(context).pop(KeyMissingChoice.phrase),
          child: const Text('Use recovery phrase'),
        ),
        HollowButton.filled(
          onPressed: _retry,
          loading: actionRunning,
          child: const Text('Try again'),
        ),
      ],
    );
  }
}

/// The phrase must open this profile's messages first, so another identity's
/// phrase can never take the place of the one on this computer.
Future<bool> _restoreWithPhrase(BuildContext context) async {
  final done = await showHollowDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RecoveryPhraseDialog(
      title: 'Restore with your recovery phrase',
      paragraphs: const [
        'Type your recovery phrase. Hollow sets up your identity again on '
            'this computer, and your messages stay.',
        'This computer then joins as a new device.',
      ],
      confirmLabel: 'Restore',
      onRecover: (phrase) async {
        final words = phrase.toLowerCase();
        if (!await identity_api.recoveryPhraseFitsThisProfile(phrase: words)) {
          throw const FriendlyException(
              'That phrase belongs to a different identity than the one on '
              'this computer.');
        }
        await identity_api.restoreIdentityFromMnemonic(phrase: words);
        await identity_api.unlockIdentity();
        // The restore leaves the keys unlocked: the person is asked to pick a
        // lock again, never locked to a keychain that just failed them.
        await storage_api
            .saveSetting(key: kProtectionOfferDueKey, value: '1')
            .catchError((_) {});
      },
    ),
  );
  return done == true;
}

Future<bool> _restoreFromBackup(BuildContext context) async {
  final done = await showHollowDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _BackupRestoreDialog(),
  );
  return done == true;
}

class _BackupRestoreDialog extends StatefulWidget {
  const _BackupRestoreDialog();

  @override
  State<_BackupRestoreDialog> createState() => _BackupRestoreDialogState();
}

class _BackupRestoreDialogState extends State<_BackupRestoreDialog>
    with HollowDialogAction {
  final _pass = TextEditingController();
  String? _path;
  String? _name;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Choose a backup',
      type: FileType.custom,
      allowedExtensions: const ['hollow'],
    );
    final picked = result?.files.single;
    if (picked?.path == null || !mounted) return;
    setState(() {
      _path = picked!.path;
      _name = picked.name;
      actionError = null;
    });
  }

  Future<void> _restore() async {
    final path = _path;
    // Never trimmed: a passphrase may begin or end with a space.
    final passphrase = _pass.text;
    if (path == null || passphrase.isEmpty) return;
    final ok = await runDialogAction(() async {
      try {
        await storage_api.importBackup(backupPath: path, passphrase: passphrase);
      } catch (e) {
        if ('$e'.toLowerCase().contains('wrong passphrase')) {
          throw const FriendlyException(
              'That passphrase does not open this backup.');
        }
        rethrow;
      }
      await identity_api.unlockIdentity();
    }, fallback: "Hollow couldn't open this backup. Try again.");
    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final ready = _path != null && _pass.text.isNotEmpty;
    return HollowDialog(
      title: 'Restore a backup',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowDialogText(
              'Pick the backup file you saved and type its passphrase. It '
              'replaces everything in this Hollow folder, so messages newer '
              "than the backup won't be on this computer."),
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'Backup file'),
          const SizedBox(height: HollowSpacing.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  _name ?? 'No file chosen',
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.body.copyWith(
                    color: _name == null ? hollow.textTertiary : hollow.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.ghost(
                compact: true,
                onPressed: actionRunning ? null : _pick,
                child: const Text('Choose file'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          const SettingsFieldLabel(label: 'Passphrase'),
          const SizedBox(height: HollowSpacing.xs),
          HollowTextField(
            controller: _pass,
            obscureText: true,
            onChanged: (_) => setState(() => actionError = null),
            onSubmitted: (_) => _restore(),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed:
              actionRunning ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: ready ? _restore : null,
          loading: actionRunning,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

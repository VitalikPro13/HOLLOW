import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/recovery_phrase_dialogs.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';

/// Locking an identity to this computer's keychain: the key that encrypts the
/// identity file lives in the OS keystore of this account (design rules agreed
/// for 0.12.1). Turning it on always takes the recovery phrase, because the
/// phrase is the way back if the keystore ever loses the key.

/// Settings key for the one-time offer to an identity that predates the
/// default. Set when the offer shows, so it shows once.
const kKeychainOfferShownKey = 'keychain_offer_shown';

/// Whether to show the one-time offer now, and if so marks it shown: Windows
/// and macOS on the OS's own data root, a plaintext identity only (a password
/// stays as it is), not while the stored phrase from before 0.12 waits to be
/// confirmed, and never twice.
Future<bool> claimKeychainOffer({bool? keystorePlatform}) async {
  if (!(keystorePlatform ?? (Platform.isWindows || Platform.isMacOS))) {
    return false;
  }
  try {
    if (!await identity_api.keychainDefaultEligible()) return false;
    if ((await identity_api.getIdentityProtectionStatus()).isEncrypted) {
      return false;
    }
    if (await roster_api.storedPhraseForUpgrade() != null) return false;
    if (await storage_api.loadSetting(key: kKeychainOfferShownKey) == '1') {
      return false;
    }
    await storage_api.saveSetting(key: kKeychainOfferShownKey, value: '1');
    return true;
  } catch (e) {
    debugPrint('[HOLLOW] Keychain offer skipped: $e');
    return false;
  }
}

/// The keystore as the person knows it.
String keychainStoreName() =>
    Platform.isMacOS ? "your Mac's keychain" : 'Windows Credential Manager';

/// A new identity's default, run once its person typed words of the phrase
/// back. Says what happened in a toast; a failure leaves the identity as it
/// was and says that too.
Future<void> applyDefaultKeychainProtection(
    ProviderContainer container, String phrase) async {
  bool locked;
  try {
    locked = await identity_api.protectNewIdentityByDefault(phrase: phrase);
  } catch (e) {
    _toast(friendlyError(e), HollowToastType.error);
    return;
  }
  if (!locked) return;
  container.invalidate(identityProtectionProvider);
  _toast('Your identity is now locked to this computer. You can change that '
      'in Settings, under Security.', HollowToastType.success);
}

void _toast(String message, HollowToastType type) {
  final overlay = hollowNavigatorKey.currentState?.overlay;
  final context = hollowNavigatorKey.currentContext;
  if (overlay == null || context == null) return;
  HollowToast.show(context, message,
      type: type, overlayState: overlay, duration: const Duration(seconds: 5));
}

/// The one-time offer to an identity that predates the default. True once it is
/// locked; "Not now" and a wrong phrase leave it exactly as it was.
Future<bool> showKeychainOfferDialog(BuildContext context) async {
  final done = await showHollowDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const KeychainPhraseDialog(
      title: 'Lock your identity to this computer?',
      cancelLabel: 'Not now',
      note: 'You can change this later in Settings, under Security.',
    ),
  );
  return done ?? false;
}

/// Settings' way to turn it on.
Future<bool> showTurnOnKeychainDialog(BuildContext context) async {
  final done = await showHollowDialog<bool>(
    context: context,
    builder: (_) => const KeychainPhraseDialog(
      title: 'Lock to this computer',
      cancelLabel: 'Cancel',
    ),
  );
  return done ?? false;
}

/// Settings' way to turn it off: back to a plain identity file.
Future<bool> showTurnOffKeychainDialog(BuildContext context) {
  return showHollowConfirm(
    context: context,
    title: 'Turn off the lock to this computer?',
    message: 'Your identity file is stored unencrypted again, so anyone who '
        'copies it can use your identity.',
    confirmLabel: 'Turn off',
    onConfirm: identity_api.disableOsKeychainProtection,
  );
}

/// Explains the lock and takes the whole recovery phrase. Pops true once the
/// identity is locked.
class KeychainPhraseDialog extends StatefulWidget {
  final String title;
  final String cancelLabel;
  final String? note;

  const KeychainPhraseDialog({
    super.key,
    required this.title,
    required this.cancelLabel,
    this.note,
  });

  @override
  State<KeychainPhraseDialog> createState() => _KeychainPhraseDialogState();
}

class _KeychainPhraseDialogState extends State<KeychainPhraseDialog>
    with HollowDialogAction {
  final _phrase = TextEditingController();
  String? _phraseError;

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  String get _typed =>
      _phrase.text.trim().split(RegExp(r'\s+')).join(' ').toLowerCase();

  Future<void> _submit() async {
    if (actionRunning || _phrase.text.trim().isEmpty) return;
    var wrong = false;
    final ok = await runDialogAction(() async {
      try {
        await identity_api.enableOsKeychainProtectionWithPhrase(phrase: _typed);
      } catch (e) {
        if ('$e'.contains('recovery phrase')) {
          wrong = true;
          return;
        }
        rethrow;
      }
    });
    if (!mounted) return;
    if (wrong) {
      // Ended without a pop, so the running state is this dialog's to clear.
      setState(() {
        actionRunning = false;
        _phraseError = kWrongPhraseText;
      });
      return;
    }
    if (ok) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final note = widget.note;
    return HollowDialog(
      title: widget.title,
      width: 440,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText('Hollow can encrypt your identity file with a key '
              'that ${keychainStoreName()} keeps for your account. A copy of '
              "the file then won't open on any other computer."),
          const SizedBox(height: HollowSpacing.md),
          const HollowDialogText('If that key is ever lost, for example after '
              'a password reset or a reinstall, your recovery phrase is the way '
              "back in. That's why Hollow asks for it here."),
          const SizedBox(height: HollowSpacing.lg),
          const SettingsFieldLabel(label: 'Recovery phrase'),
          const SizedBox(height: HollowSpacing.xs),
          RecoveryPhraseField(
            controller: _phrase,
            autofocus: true,
            errorText: _phraseError,
            onChanged: (_) => setState(() {
              _phraseError = null;
              actionError = null;
            }),
          ),
          if (note != null) ...[
            const SizedBox(height: HollowSpacing.md),
            Text(note,
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary)),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed:
              actionRunning ? null : () => Navigator.of(context).pop(false),
          child: Text(widget.cancelLabel),
        ),
        HollowButton.filled(
          onPressed: _phrase.text.trim().isEmpty ? null : _submit,
          loading: actionRunning,
          child: const Text('Turn on'),
        ),
      ],
    );
  }
}

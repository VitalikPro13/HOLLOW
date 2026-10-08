import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/keychain_protection_dialogs.dart'
    show kKeychainOfferShownKey;
import 'package:hollow/src/ui/settings/security_section.dart'
    show setAppPasswordFlow, setPhoneLockFlow;

/// Rust sets it when a link or a restore lands an identity (`PROTECTION_OFFER_DUE`
/// in `api/storage.rs`); the offer clears it.
const kProtectionOfferDueKey = 'protection_offer_due';

/// What the person chose in [ProtectionPrompt]; null is "Not now".
enum ProtectionChoice { password, keychain }

/// A linked or restored device lands its keys unprotected whatever its source used
/// (C-IDENTITY-15), so its first start offers a lock, once: cleared before it shows,
/// skipped when a lock is already set. The caller runs it only once the app lock's
/// cover is down; nothing here locks or blocks.
Future<void> offerProtectionIfDue(BuildContext context, {bool? phone}) async {
  identity_api.ProtectionStatus status;
  final isPhone = phone ?? (Platform.isAndroid || Platform.isIOS);
  var keychain = false;
  try {
    if (await storage_api.loadSetting(key: kProtectionOfferDueKey) != '1') {
      return;
    }
    await storage_api.saveSetting(key: kProtectionOfferDueKey, value: '');
    // This offer stands in for the keychain one, which must not ask again.
    await storage_api.saveSetting(key: kKeychainOfferShownKey, value: '1');
    status = await identity_api.getIdentityProtectionStatus();
    // A machine-bound lock only where the default would apply (never portable,
    // a data-dir override or Linux).
    keychain = !isPhone && await identity_api.keychainDefaultEligible();
  } catch (e) {
    debugPrint('[HOLLOW] Lock offer skipped: $e');
    return;
  }
  if (status.isEncrypted || !context.mounted) return;
  final choice = await showHollowDialog<ProtectionChoice>(
    context: context,
    builder: (_) => ProtectionPrompt(phone: isPhone, keychain: keychain),
  );
  if (choice == null || !context.mounted) return;
  final String? done;
  switch (choice) {
    case ProtectionChoice.keychain:
      done = 'Your identity is encrypted on this computer';
    case ProtectionChoice.password:
      if (isPhone) {
        final type = await setPhoneLockFlow(context);
        done = type == null ? null : (type == 'pin' ? 'PIN set' : 'Password set');
      } else {
        done = await setAppPasswordFlow(context) ? 'App lock enabled' : null;
      }
  }
  if (!context.mounted) return;
  ProviderScope.containerOf(context, listen: false)
      .invalidate(identityProtectionProvider);
  if (done == null) return;
  HollowToast.show(context, done, type: HollowToastType.success);
}

/// The offer itself: a password (a PIN or password on a phone), the system
/// keychain where this desktop has one, or not now.
class ProtectionPrompt extends StatefulWidget {
  final bool phone;
  final bool keychain;

  const ProtectionPrompt({super.key, required this.phone, required this.keychain});

  @override
  State<ProtectionPrompt> createState() => _ProtectionPromptState();
}

class _ProtectionPromptState extends State<ProtectionPrompt>
    with HollowDialogAction {
  Future<void> _useKeychain() async {
    if (await runDialogAction(identity_api.enableOsKeychainProtection) &&
        mounted) {
      Navigator.of(context).pop(ProtectionChoice.keychain);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.phone ? 'phone' : 'computer';
    return HollowDialog(
      title: 'Set a lock on this device',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowDialogText(
            'A linked or restored device starts without a lock, even if your '
            'other device has one. Until you set one, anyone who uses this '
            '$device can copy your identity.',
          ),
          if (widget.keychain) ...[
            const SizedBox(height: HollowSpacing.md),
            const HollowDialogText(
              'The keychain encrypts your identity and lets Hollow open '
              'without asking. A password also locks Hollow when you step '
              'away.',
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Not now'),
        ),
        if (widget.keychain)
          HollowButton.outline(
            onPressed: actionRunning ? null : _useKeychain,
            loading: actionRunning,
            child: const Text('Use the keychain'),
          ),
        HollowButton.filled(
          onPressed: actionRunning
              ? null
              : () => Navigator.of(context).pop(ProtectionChoice.password),
          child: Text(widget.phone ? 'Set a lock' : 'Set a password'),
        ),
      ],
    );
  }
}

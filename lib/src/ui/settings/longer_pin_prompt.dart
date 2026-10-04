import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/security_section.dart';

/// Asked once, after an unlock with a secret of digits shorter than
/// [kMinPinDigits]. The old one keeps working, and "Not now" ends it.
Future<void> offerLongerPin(
  BuildContext context, {
  required String current,
  required bool isPin,
}) async {
  final word = isPin ? 'PIN' : 'password';
  final wanted = await showHollowConfirm(
    context: context,
    title: 'Choose a longer $word?',
    message: isPin
        ? 'PINs now need at least $kMinPinDigits digits. Yours still works, '
            'and a longer one is much harder to guess if someone copies the '
            'data on this device.'
        : 'A password of only digits now needs at least $kMinPinDigits of '
            'them. Yours still works, and a longer one is much harder to '
            'guess if someone copies the data on this device.',
    confirmLabel: 'Choose a new $word',
    cancelLabel: 'Not now',
  );
  if (!wanted || !context.mounted) return;
  final next = await askSecretDialog(
    context,
    title: 'Choose a new $word',
    ask: SecretAsk.create,
    isPin: isPin,
    confirmLabel: 'Save',
    onSubmit: (_, next) => changeAppLockSecret(current: current, next: next),
  );
  if (next == null || !context.mounted) return;
  HollowToast.show(context, isPin ? 'PIN changed' : 'Password changed',
      type: HollowToastType.success);
}

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart'
    show openMobileSettingsPage;

const kAgeRestrictedTitle = 'Age-restricted server';
const kAgeRestrictedIosBody =
    "This server is marked for adults, so it's hidden on this device. You can "
    'allow age-restricted servers from Hollow on a computer, in its Settings.';
const kAgeRestrictedAndroidBody =
    'This server is marked for adults. Age-restricted servers are off on this '
    'phone, and you can turn them on in Settings.';

/// A phone that hides age-restricted servers asked to join one, or tapped one it
/// already holds: say why nothing opens. iPhone has no setting to point at.
Future<void> showAgeRestrictedJoinDialog(
    BuildContext context, AgeGateMode mode) async {
  if (mode == AgeGateMode.phoneLocal) {
    final open = await showHollowConfirm(
      context: context,
      title: kAgeRestrictedTitle,
      message: kAgeRestrictedAndroidBody,
      cancelLabel: 'Not now',
      confirmLabel: 'Open settings',
    );
    final ctx = hollowNavigatorKey.currentContext;
    if (open && ctx != null && ctx.mounted) {
      openMobileSettingsPage(ctx, SettingsCategory.network);
    }
    return;
  }
  await showHollowDialog<void>(
    context: context,
    builder: (_) => const HollowDialog(
      title: kAgeRestrictedTitle,
      showClose: true,
      content: HollowDialogText(kAgeRestrictedIosBody),
    ),
  );
}

/// The desktop switch turned on: the choice reaches every phone of ours.
Future<bool> confirmAllowOnPhones(BuildContext context,
        Future<void> Function() onConfirm) =>
    showHollowConfirm(
      context: context,
      title: 'Allow on your phones?',
      message: 'Servers marked for adults will show on every phone linked to '
          'you, including phones you link later. Only turn this on if everyone '
          'using them is 18 or older.',
      confirmLabel: 'Allow',
      onConfirm: onConfirm,
    );

/// The sideloaded Android toggle turned on.
Future<bool> confirmAllowOnThisPhone(BuildContext context,
        Future<void> Function() onConfirm) =>
    showHollowConfirm(
      context: context,
      title: 'Allow age-restricted servers?',
      message: 'Servers marked for adults will show on this phone. Only turn '
          "this on if you're 18 or older.",
      confirmLabel: 'Allow',
      onConfirm: onConfirm,
    );

/// Right after this computer's own 18+ join: offer the phones' setting once.
Future<void> offerAgeGateForPhones(Ref ref) async {
  final gate = ref.read(ageGateProvider.notifier);
  await gate.load();
  final state = ref.read(ageGateProvider);
  if (state.asked || state.phonesAllow) return;
  await gate.markAsked();
  final ctx = hollowNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  await showHollowConfirm(
    context: ctx,
    title: 'Show age-restricted servers on your phones?',
    message: 'Phones hide servers marked for adults until you allow them from '
        'a computer. Only allow it if everyone using your phones, including '
        'phones you link later, is 18 or older. You can change this any time '
        'in Settings.',
    cancelLabel: 'Not now',
    confirmLabel: 'Allow on my phones',
    onConfirm: () => gate.setForPhones(true),
  );
}

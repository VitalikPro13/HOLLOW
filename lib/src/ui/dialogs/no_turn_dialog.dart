import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart'
    show openMobileSettingsPage;

/// Forces the phone path in tests, where `Platform` is the host's.
@visibleForTesting
bool? debugNoTurnPhoneOverride;

/// The refusal's title; the fleet relay-switch run waits on it.
const kNoTurnDialogTitle = "This relay can't carry your call";

/// True when a call may be dialled. Always-relay routes every call through
/// TURN, so on a relay that has none the connection can only fail; say so
/// before the ringing starts rather than after.
Future<bool> ensureTurnForCall(BuildContext context, WidgetRef ref) =>
    _ensureTurn(
      context,
      alwaysRelay: ref.read(alwaysRelayCallsProvider),
      turn: ref.read(relayStatusProvider)?.turn,
    );

/// The same gate for provider code, which holds no BuildContext of its own.
Future<bool> ensureTurnForCallFromRef(Ref ref) async {
  if (!ref.read(alwaysRelayCallsProvider)) return true;
  if (ref.read(relayStatusProvider)?.turn != false) return true;
  final context = hollowNavigatorKey.currentContext;
  if (context == null || !context.mounted) return false;
  return _ensureTurn(context, alwaysRelay: true, turn: false);
}

Future<bool> _ensureTurn(
  BuildContext context, {
  required bool alwaysRelay,
  required bool? turn,
}) async {
  if (!alwaysRelay || turn != false) return true;

  final read = ProviderScope.containerOf(context, listen: false).read;
  final onPhone =
      debugNoTurnPhoneOverride ?? (Platform.isAndroid || Platform.isIOS);
  await showHollowDialog<void>(
    context: context,
    builder: (dialogContext) {
      return HollowDialog(
        title: kNoTurnDialogTitle,
        width: 420,
        content: const HollowDialogText(
          'Always relay calls is on, so every call has to pass through the '
          "relay, and this relay doesn't offer that. Turn off Always relay "
          'calls in Security settings to call from here.',
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          HollowButton.filled(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              if (!onPhone) {
                openSettings(read, category: SettingsCategory.security);
                return;
              }
              // The phone's Settings is a tab of its own; the page is pushed
              // over wherever the call was dialled from.
              final host = context.mounted
                  ? context
                  : hollowNavigatorKey.currentContext;
              if (host != null) {
                openMobileSettingsPage(host, SettingsCategory.security);
              }
            },
            child: const Text('Open Security settings'),
          ),
        ],
      );
    },
  );
  return false;
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

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

  await showHollowDialog<void>(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);
      return HollowDialog(
        title: 'Always relay calls needs a TURN server',
        content: Text(
          'This relay has no TURN server, so a relayed call cannot be set up. '
          'Turn off Always relay calls in Settings > Security to call on this '
          'relay.',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
        actions: [
          HollowButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      );
    },
  );
  return false;
}

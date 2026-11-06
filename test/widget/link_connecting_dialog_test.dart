/// #123: on a members-only relay, a refused access key on the "Link a device"
/// path opens a key prompt above the "Connecting" placeholder. Taking the
/// placeholder away must never take that prompt with it, or the person is left
/// on a link screen that never connects, and a relaunch lands on the throwaway.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';

class _OwnRelay extends RelayDomainNotifier {
  @override
  String build() => 'myrelay.duckdns.org';
}

Future<BuildContext> _pump(WidgetTester tester) async {
  late BuildContext home;
  await tester.pumpWidget(MaterialApp(
    navigatorKey: hollowNavigatorKey,
    theme: HollowThemeData.dark(),
    home: Builder(builder: (context) {
      home = context;
      return const SizedBox();
    }),
  ));
  return home;
}

/// The placeholder's spinner never settles, so routes are given their time.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the connecting placeholder goes, a prompt above it stays',
      (tester) async {
    final home = await _pump(tester);
    showConnectingDialog(home, message: 'Connecting to link your device…');
    await _settle(tester);

    String? answered = 'unanswered';
    unawaited(showHollowDialog<String>(
      context: home,
      barrierDismissible: false,
      builder: (_) => const HollowDialog(
        title: 'This relay needs an access key',
        content: SizedBox(),
      ),
    ).then((v) => answered = v));
    await _settle(tester);

    dismissConnectingDialog();
    await _settle(tester);

    expect(find.text('This relay needs an access key'), findsOneWidget);
    expect(answered, 'unanswered', reason: 'the key prompt was closed for it');
    expect(find.text('Connecting to link your device…'), findsNothing);
  });

  testWidgets('a placeholder taken away before its first frame still goes',
      (tester) async {
    final home = await _pump(tester);
    showConnectingDialog(home, message: 'Connecting to link your device…');
    dismissConnectingDialog();
    await _settle(tester);
    expect(find.text('Connecting to link your device…'), findsNothing);
    expect(Navigator.of(home).canPop(), isFalse);
  });

  testWidgets('a device being linked is asked for the key its other device uses',
      (tester) async {
    late BuildContext home;
    await tester.pumpWidget(ProviderScope(
      overrides: [relayDomainProvider.overrideWith(_OwnRelay.new)],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Builder(builder: (context) {
          home = context;
          return const SizedBox();
        }),
      ),
    ));
    unawaited(showLicenseKeyDialog(home, linking: true));
    await _settle(tester);
    expect(
        find.textContaining('Enter the one your other device uses',
            findRichText: true),
        findsOneWidget);
    expect(find.textContaining('Ask them for one', findRichText: true),
        findsNothing);
    expect(find.text('Use the default relay and close'), findsNothing);
    expect(find.text('Use the default relay'), findsOneWidget);
  });
}

// #153: a relay that turns our login away because every device seat of our access
// key is taken says so in the persistent status, never "No connection", and the
// status opens what to do about it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/link_down_provider.dart';
import 'package:hollow/src/rust/api/network.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/connection_visual.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/access_key_full_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_connection_indicator.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';

import '../helpers/test_app.dart';

Future<ProviderContainer> _mount(WidgetTester tester, {required bool full}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      connectionStatusProvider.overrideWith(
          () => TestRelayStatus(RelayConnectionStatus.disconnected)),
      relayKeyFullProvider.overrideWith((ref) => full),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: Stack(children: [MobileConnectionIndicator()])),
    ),
  ));
  await tester.pump(kConnectionIndicatorDelay);
  await tester.pump(const Duration(milliseconds: 300));
  return ProviderScope.containerOf(
      tester.element(find.byType(MobileConnectionIndicator)));
}

/// A key that cannot be saved: replacing it fails.
class _KeyThatFails extends LicenseKeyNotifier {
  @override
  String? build() => 'AAAA-BBBB-CCCC-DDDD';

  @override
  Future<void> setKey(String key) async => throw StateError('no store');
}

/// Opens the key prompt with [onKey]; resolves to what it returned.
Future<Future<String?>> _openPrompt(WidgetTester tester,
    Future<void> Function(String key) onKey) async {
  late Future<String?> result;
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => result =
                showLicenseKeyDialog(context, cancellable: true, onKey: onKey),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'WXYZ1234ABCD5678');
  await tester.pump();
  return result;
}

void main() {
  testWidgets('a full key reads as a full key, never as no connection',
      (tester) async {
    final c = await _mount(tester, full: true);
    expect(c.read(overallConnectionProvider), OverallConnection.keyFull);
    expect(find.text(kAccessKeyFullStatus), findsOneWidget);
    expect(find.text('No connection'), findsNothing);
    expect(OverallConnection.keyFull.isDown, isTrue);
    expect(OverallConnection.keyFull.isOnline, isFalse);

    c.read(relayKeyFullProvider.notifier).state = false;
    expect(c.read(overallConnectionProvider), OverallConnection.offline,
        reason: 'a key that is no longer full is just a link that is down');
  });

  testWidgets('the status opens what to do, and another key can be entered',
      (tester) async {
    final c = await _mount(tester, full: true);
    await tester.tap(find.text(kAccessKeyFullStatus));
    await tester.pumpAndSettle();
    expect(find.text(kAccessKeyFullTitle), findsOneWidget);
    expect(find.text(kAccessKeyFullText), findsOneWidget);
    expect(kAccessKeyFullText, contains('a key of your own'));
    expect(kAccessKeyFullText, contains('close Hollow on another device'));

    await tester.tap(find.text('Enter another key'));
    await tester.pumpAndSettle();
    expect(find.text(kAccessKeyFullTitle), findsNothing);
    expect(find.text('This relay needs an access key'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('This relay needs an access key'), findsNothing);
    expect(c.read(relayKeyFullProvider), isTrue,
        reason: 'Cancel keeps the key and its state as they were');
  });

  testWidgets('the relay\'s full-key answer sets it, its welcome clears it',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: const MaterialApp(home: SizedBox()),
    ));
    final c = ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
    final events = c.read(eventStreamProvider.notifier);
    events.debugDispatch(
        const NetworkEvent.licenseError(reason: 'invalid_license_key'));
    expect(c.read(relayKeyFullProvider), isFalse,
        reason: 'only the full-key answer means a full key');
    events.debugDispatch(
        const NetworkEvent.licenseError(reason: 'license_key_in_use'));
    expect(c.read(relayKeyFullProvider), isTrue);
    expect(c.read(licenseErrorProvider), 'license_key_in_use',
        reason: 'the shell still hears it once, for its toast');
    events.debugDispatch(const NetworkEvent.relayConnected());
    expect(c.read(relayKeyFullProvider), isFalse);
  });

  // Review item 4: the node ends a full-key spell when a login fails for another
  // reason, and that word is no refusal of its own.
  testWidgets('a login failing for another reason ends the full-key state',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: const MaterialApp(home: SizedBox()),
    ));
    final c = ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
    final events = c.read(eventStreamProvider.notifier);
    events.debugDispatch(
        const NetworkEvent.licenseError(reason: kLicenseKeyInUse));
    expect(c.read(relayKeyFullProvider), isTrue);
    c.read(licenseErrorProvider.notifier).state = null;
    events.debugDispatch(
        const NetworkEvent.licenseError(reason: kLicenseKeyNotFull));
    expect(c.read(relayKeyFullProvider), isFalse);
    expect(c.read(licenseErrorProvider), isNull,
        reason: 'no prompt, no toast: nothing was refused');
    events.debugDispatch(
        const NetworkEvent.licenseError(reason: kLicenseKeyInUse));
    events.debugDispatch(
        const NetworkEvent.licenseError(reason: 'invalid_license_key'));
    expect(c.read(relayKeyFullProvider), isFalse,
        reason: 'a refused key is not a full one');
  });

  // Review item 3: every line about the down link says why, never "offline".
  testWidgets('surfaces about the link name the full key', (tester) async {
    final full = await _mount(tester, full: true);
    expect(full.read(linkDownProvider), LinkDown.keyFull);
    full.read(relayKeyFullProvider.notifier).state = false;
    expect(full.read(linkDownProvider), LinkDown.offline);
    for (final note in LinkNote.values) {
      final s = linkDownNote(LinkDown.keyFull, note);
      expect(s, isNot(linkDownNote(LinkDown.offline, note)), reason: '$note');
      expect(s.toLowerCase(), isNot(contains('offline')), reason: '$note');
      expect(s.contains('\u2014') || s.contains(':'), isFalse, reason: s);
    }
    expect(linkDownNote(LinkDown.keyFull, LinkNote.title), kAccessKeyFullTitle);
  });

  // Review item 5: a new key is applied inside its prompt, never after a pop.
  testWidgets('the prompt waits for the new key to apply, then closes',
      (tester) async {
    final applying = Completer<void>();
    String? applied;
    final result = await _openPrompt(tester, (key) {
      applied = key;
      return applying.future;
    });
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(applied, 'WXYZ-1234-ABCD-5678');
    expect(find.text('This relay needs an access key'), findsOneWidget,
        reason: 'open while the key applies');
    expect(
        tester.widget<HollowButton>(find.ancestor(
            of: find.text('Connect'), matching: find.byType(HollowButton))).loading,
        isTrue);
    applying.complete();
    await tester.pumpAndSettle();
    expect(find.text('This relay needs an access key'), findsNothing);
    expect(await result, 'WXYZ-1234-ABCD-5678');
  });

  testWidgets('a key that fails to apply says so and keeps the prompt',
      (tester) async {
    final result = await _openPrompt(
        tester, (key) async => throw Exception('restart failed'));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('This relay needs an access key'), findsOneWidget);
    expect(find.text("Couldn't reconnect with this key. Try again."),
        findsOneWidget);
    expect(find.text('WXYZ-1234-ABCD-5678'), findsOneWidget,
        reason: 'the typed key stays');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('entering another key from the notice reports a failure',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        connectionStatusProvider.overrideWith(
            () => TestRelayStatus(RelayConnectionStatus.disconnected)),
        relayKeyFullProvider.overrideWith((ref) => true),
        licenseKeyProvider.overrideWith(_KeyThatFails.new),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: Stack(children: [MobileConnectionIndicator()])),
      ),
    ));
    await tester.pump(kConnectionIndicatorDelay);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(kAccessKeyFullStatus));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter another key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'WXYZ1234ABCD5678');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't reconnect with this key. Try again."),
        findsOneWidget,
        reason: 'never a silent failure after the notice closed');
  });

  testWidgets('the desktop user bar says it and opens what to do',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        connectionStatusProvider.overrideWith(
            () => TestRelayStatus(RelayConnectionStatus.disconnected)),
        relayKeyFullProvider.overrideWith((ref) => true),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(width: 240, child: UserBar()),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('No connection'), findsNothing);
    await tester.tap(find.text(kAccessKeyFullStatus));
    await tester.pumpAndSettle();
    expect(find.byType(AccessKeyFullDialog), findsOneWidget);
  });

  testWidgets('a link that is merely down still says no connection',
      (tester) async {
    await _mount(tester, full: false);
    expect(find.text('No connection'), findsOneWidget);
    expect(find.text(kAccessKeyFullStatus), findsNothing);
  });

  test('a full key shows through Invisible, as a warning ring', () {
    final hollow = HollowTheme.dark();
    final v = connectionVisual(hollow, OverallConnection.keyFull, invisible: true);
    expect(v.label, kAccessKeyFullStatus);
    expect(v.color, hollow.warning);
    expect(v.filled, isFalse);
  });

  testWidgets('showAccessKeyFull opens one notice at a time', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                showAccessKeyFull(context);
                showAccessKeyFull(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(kAccessKeyFullTitle), findsOneWidget);
  });
}

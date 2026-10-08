/// A linked or restored device starts without a lock (C-IDENTITY-15): the first
/// start after it offers one, once, and only while nothing protects the identity.
/// "Not now" is always there; the keychain only on a desktop that has one.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/keychain_protection_dialogs.dart'
    show kKeychainOfferShownKey;
import 'package:hollow/src/ui/dialogs/protection_prompt.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';

import '../helpers/test_app.dart';

class _Api implements RustLibApi {
  final settings = <String, String>{};
  bool encrypted = false;
  bool keychainAvailable = true;
  bool keychainEligible = true;
  int keychainCalls = 0;

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async => settings[key];

  @override
  Future<void> crateApiStorageSaveSetting({required String key, required String value}) async =>
      settings[key] = value;

  @override
  Future<identity_api.ProtectionStatus> crateApiIdentityGetIdentityProtectionStatus() async =>
      identity_api.ProtectionStatus(
        isEncrypted: encrypted,
        hasPassword: false,
        hasOsKeychain: encrypted,
        osKeychainAvailable: keychainAvailable,
      );

  @override
  Future<bool> crateApiIdentityKeychainDefaultEligible() async => keychainEligible;

  @override
  Future<void> crateApiIdentityEnableOsKeychainProtection() async {
    keychainCalls++;
    encrypted = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.settings
      ..clear()
      ..[kProtectionOfferDueKey] = '1';
    api.encrypted = false;
    api.keychainAvailable = true;
    api.keychainEligible = true;
    api.keychainCalls = 0;
  });

  late BuildContext host;

  Future<void> pumpDesktop(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (context) {
          host = context;
          return const SizedBox.expand();
        })),
      ),
    ));
  }

  testWidgets('offered once after a link or restore, and Not now is the end of it',
      (tester) async {
    await pumpDesktop(tester);
    final offered = offerProtectionIfDue(host, phone: false);
    await tester.pumpAndSettle();
    expect(find.text('Set a lock on this device'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(find.text('Use the keychain'), findsOneWidget);
    expect(find.text('Set a password'), findsOneWidget);
    expect(api.settings[kProtectionOfferDueKey], '', reason: 'cleared as it shows, so a close never brings it back');
    expect(api.settings[kKeychainOfferShownKey], '1', reason: 'the keychain offer must not ask again');

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    await offered;
    expect(find.text('Set a lock on this device'), findsNothing);

    final again = offerProtectionIfDue(host, phone: false);
    await tester.pumpAndSettle();
    await again;
    expect(find.text('Set a lock on this device'), findsNothing, reason: 'shown once');
  });

  testWidgets('nothing is offered without a link or a restore', (tester) async {
    api.settings.remove(kProtectionOfferDueKey);
    await pumpDesktop(tester);
    final offered = offerProtectionIfDue(host, phone: false);
    await tester.pumpAndSettle();
    await offered;
    expect(find.text('Set a lock on this device'), findsNothing);
  });

  testWidgets('an identity already protected is not asked, and the offer is spent',
      (tester) async {
    api.encrypted = true;
    await pumpDesktop(tester);
    final offered = offerProtectionIfDue(host, phone: false);
    await tester.pumpAndSettle();
    await offered;
    expect(find.text('Set a lock on this device'), findsNothing);
    expect(api.settings[kProtectionOfferDueKey], '');
  });

  testWidgets('the keychain is set from the prompt', (tester) async {
    await pumpDesktop(tester);
    final offered = offerProtectionIfDue(host, phone: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use the keychain'));
    await tester.pumpAndSettle();
    await offered;
    expect(api.keychainCalls, 1);
    expect(find.text('Set a lock on this device'), findsNothing);
    expect(find.text('Your identity is encrypted on this computer'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('the keychain only where the default would apply', (tester) async {
    api.keychainEligible = false;
    await pumpDesktop(tester);
    unawaited(offerProtectionIfDue(host, phone: false));
    await tester.pumpAndSettle();
    expect(find.text('Set a lock on this device'), findsOneWidget);
    expect(find.text('Use the keychain'), findsNothing,
        reason: 'portable, a data-dir override or Linux');
    expect(find.text('Set a password'), findsOneWidget);
  });

  testWidgets('a password goes to the app password dialog', (tester) async {
    api.keychainAvailable = false;
    api.keychainEligible = false;
    await pumpDesktop(tester);
    unawaited(offerProtectionIfDue(host, phone: false));
    await tester.pumpAndSettle();
    expect(find.text('Use the keychain'), findsNothing, reason: 'no keychain on this desktop');
    await tester.tap(find.text('Set a password'));
    await tester.pumpAndSettle();
    expect(find.text('Set app password'), findsOneWidget);
  });

  testWidgets('phone: a PIN or password, never the keychain', (tester) async {
    await pumpHollowMobile(tester);
    unawaited(offerProtectionIfDue(tester.element(find.byType(MobileShell)), phone: true));
    await tester.pumpAndSettle();
    expect(find.text('Set a lock on this device'), findsOneWidget);
    expect(find.textContaining('anyone who uses this phone'), findsOneWidget);
    expect(find.text('Use the keychain'), findsNothing);
    await tester.tap(find.text('Set a lock'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a lock'), findsOneWidget);
  });
}

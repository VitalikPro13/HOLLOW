import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/duress_section.dart';

import '../helpers/test_app.dart';

/// Rust as the dialogs see it: every call answers with [error] when set.
class _DuressApi implements RustLibApi {
  Object? error;
  int saves = 0;
  int clears = 0;
  int destroys = 0;

  @override
  Future<void> crateApiIdentitySetDuressCode({
    required String password,
    required String duressCode,
    required String scope,
    required bool notifyFriends,
  }) async {
    saves++;
    if (error != null) throw error!;
  }

  @override
  Future<void> crateApiIdentityClearDuressCode(
      {required String password}) async {
    clears++;
    if (error != null) throw error!;
  }

  @override
  Future<void> crateApiWipeDestroyWithScope(
      {required String scope, required bool notifyFriends}) async {
    destroys++;
    if (error != null) throw error!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The two account-destruction cards in Settings > Security.
///
/// What is pinned here is what a wrong build would silently get wrong: which
/// missing piece the unavailable copy names, the scope wording, the friend
/// toggle belonging to the identity scope alone, the Danger zone NOT offering
/// the device-only scope (the Profile tab's Erase owns that), and the typed
/// confirmation actually gating the destructive button.
void main() {
  final api = _DuressApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.error = null;
    api.saves = 0;
    api.clears = 0;
    api.destroys = 0;
  });

  identity_api.ProtectionStatus protection({
    bool hasPassword = false,
    bool hasOsKeychain = false,
  }) =>
      identity_api.ProtectionStatus(
        isEncrypted: hasPassword || hasOsKeychain,
        hasPassword: hasPassword,
        hasOsKeychain: hasOsKeychain,
        osKeychainAvailable: true,
      );

  Future<void> pumpCard(
    WidgetTester tester,
    Widget card, {
    identity_api.DuressStatus? status,
    identity_api.ProtectionStatus? protectionStatus,
  }) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(extra: [
          if (status != null)
            duressStatusProvider.overrideWith((ref) async => status),
          identityProtectionProvider
              .overrideWith((ref) async => protectionStatus ?? protection()),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: card,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('duress code card', () {
    testWidgets('with no password at all it points at password protection',
        (tester) async {
      await pumpCard(
        tester,
        const DuressCodeCard(wideScopes: false),
        status: const identity_api.DuressStatus(
          enabled: false,
          scope: 'device',
          notifyFriends: false,
          available: false,
        ),
      );

      expect(find.text('Needs a password first'), findsOneWidget);
      expect(find.text('Set up'), findsNothing);
    });

    testWidgets('the unavailable copy names password protection whatever the '
        'keychain says', (tester) async {
      await pumpCard(
        tester,
        const DuressCodeCard(wideScopes: false),
        status: const identity_api.DuressStatus(
          enabled: false,
          scope: 'device',
          notifyFriends: false,
          available: false,
        ),
        protectionStatus: protection(hasPassword: true, hasOsKeychain: true),
      );

      // A silent unlock still re-prompts at an app lock, so there is only one
      // missing piece left to name.
      expect(find.text('Needs a password first'), findsOneWidget);
    });

    testWidgets('a surface that re-unlocks a running app carries all three '
        'scopes and the warning', (tester) async {
      await pumpCard(
        tester,
        const DuressCodeCard(wideScopes: true),
        status: const identity_api.DuressStatus(
          enabled: false,
          scope: 'device',
          notifyFriends: false,
          available: true,
        ),
        protectionStatus: protection(hasPassword: true),
      );

      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();

      // A duress code on this device alone is legitimate, so all three stay.
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('This device and unlink it'), findsOneWidget);
      expect(find.text('My whole identity'), findsOneWidget);
      expect(find.textContaining('there is no undo'), findsOneWidget);
      // The reach note belongs to the wider scopes, so it waits for one.
      expect(find.textContaining('from the app lock prompt'), findsNothing);
      // The friend announcement belongs to the identity scope alone.
      expect(find.text('Tell my friends'), findsNothing);

      await tester.tap(find.text('My whole identity'));
      await tester.pumpAndSettle();
      expect(find.text('Tell my friends'), findsOneWidget);
      expect(find.byType(HollowToggle), findsOneWidget);
      // Offline devices are reached later, and that has to be said where the
      // scope is chosen.
      expect(find.textContaining('when they next connect'), findsOneWidget);
      // Worded for the device it is read on; the host here is a computer.
      expect(find.textContaining('from the app lock prompt'), findsOneWidget);
    });

    testWidgets('on a computer there are no scope chips, only the local scope',
        (tester) async {
      await pumpCard(
        tester,
        const DuressCodeCard(wideScopes: false),
        status: const identity_api.DuressStatus(
          enabled: false,
          scope: 'device',
          notifyFriends: false,
          available: true,
        ),
        protectionStatus: protection(hasPassword: true),
      );

      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();

      expect(find.textContaining('it destroys this device only'), findsOneWidget);

      expect(find.text('This device'), findsNothing);
      expect(find.text('This device and unlink it'), findsNothing);
      expect(find.text('My whole identity'), findsNothing);
      expect(find.text('Tell my friends'), findsNothing);
      expect(
        find.textContaining(
            "Deletes this device's data. Your other devices keep theirs."),
        findsOneWidget,
      );
      expect(find.textContaining('there is no undo'), findsOneWidget);
    });

    testWidgets('a code already set offers Change and Remove', (tester) async {
      await pumpCard(
        tester,
        const DuressCodeCard(wideScopes: false),
        status: const identity_api.DuressStatus(
          enabled: true,
          scope: 'identity',
          notifyFriends: true,
          available: true,
        ),
        protectionStatus: protection(hasPassword: true),
      );

      expect(find.text('Duress code'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(
        find.text('Deletes your data on every device and tells your friends.'),
        findsOneWidget,
      );
    });
  });

  group('account danger zone', () {
    testWidgets('offers unlink and whole-identity, never device only',
        (tester) async {
      await pumpCard(tester, const AccountDangerZoneCard());

      expect(find.text('Destroy device'), findsOneWidget);
      expect(find.text('Destroy identity'), findsOneWidget);

      await tester.tap(find.text('Destroy identity'));
      await tester.pumpAndSettle();

      expect(find.text('This device'), findsNothing);
      expect(find.text('This device and unlink it'), findsOneWidget);
      expect(find.text('My whole identity'), findsOneWidget);
      // The identity scope arrives preselected, so the friend toggle is there.
      expect(find.text('Tell my friends'), findsOneWidget);
      expect(find.textContaining('when they next connect'), findsOneWidget);
    });

    testWidgets('gates Destroy on the typed word', (tester) async {
      await pumpCard(tester, const AccountDangerZoneCard());

      await tester.tap(find.text('Destroy identity'));
      await tester.pumpAndSettle();

      final destroy = find.widgetWithText(HollowButton, 'Destroy');
      expect(destroy, findsOneWidget);
      expect(tester.widget<HollowButton>(destroy).onPressed, isNull);

      await tester.enterText(find.byType(TextField).last, 'destroy');
      await tester.pumpAndSettle();
      expect(tester.widget<HollowButton>(destroy).onPressed, isNull,
          reason: 'the confirmation is case sensitive');

      await tester.enterText(find.byType(TextField).last, 'DESTROY');
      await tester.pumpAndSettle();
      expect(tester.widget<HollowButton>(destroy).onPressed, isNotNull);
    });
  });

  group('the password is checked inside the dialog', () {
    const setStatus = identity_api.DuressStatus(
      enabled: true,
      scope: 'device',
      notifyFriends: false,
      available: true,
    );

    testWidgets('a wrong app password lands on its field and keeps the input',
        (tester) async {
      api.error = 'Wrong password or corrupted identity file';
      await pumpCard(tester, const DuressCodeCard(wideScopes: false),
          status: const identity_api.DuressStatus(
            enabled: false,
            scope: 'device',
            notifyFriends: false,
            available: true,
          ),
          protectionStatus: protection(hasPassword: true));

      await tester.tap(find.text('Set up'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'not it');
      await tester.enterText(fields.at(1), 'panic');
      await tester.enterText(fields.at(2), 'panic');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(api.saves, 1);
      expect(find.text("That password isn't right."), findsOneWidget);
      // Still open, and nothing typed was lost.
      expect(find.text('Set a duress code'), findsOneWidget);
      expect(
          tester.widget<TextField>(fields.at(1)).controller!.text, 'panic');
    });

    testWidgets('mismatched codes are refused on the repeat field before Rust',
        (tester) async {
      await pumpCard(tester, const DuressCodeCard(wideScopes: false),
          status: setStatus, protectionStatus: protection(hasPassword: true));

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'password');
      await tester.enterText(fields.at(1), 'panic');
      await tester.enterText(fields.at(2), 'panik');
      await tester.pump();
      await tester.tap(find.widgetWithText(HollowButton, 'Change code'));
      await tester.pumpAndSettle();

      expect(api.saves, 0);
      expect(find.text("The codes don't match."), findsOneWidget);
    });

    testWidgets('a saved code closes the dialog', (tester) async {
      await pumpCard(tester, const DuressCodeCard(wideScopes: false),
          status: setStatus, protectionStatus: protection(hasPassword: true));

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'password');
      await tester.enterText(fields.at(1), 'panic');
      await tester.enterText(fields.at(2), 'panic');
      await tester.pump();
      await tester.tap(find.widgetWithText(HollowButton, 'Change code'));
      await tester.pumpAndSettle();

      expect(api.saves, 1);
      expect(find.text('Change duress code'), findsNothing);
      // The success toast times out.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('removing the code with a wrong password stays open',
        (tester) async {
      api.error = 'Wrong password or corrupted identity file';
      await pumpCard(tester, const DuressCodeCard(wideScopes: false),
          status: setStatus, protectionStatus: protection(hasPassword: true));

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'not it');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(api.clears, 1);
      expect(find.text('Remove duress code'), findsOneWidget);
      expect(find.text("That password isn't right."), findsOneWidget);
    });
  });

  testWidgets('a failed destroy is said inside the dialog', (tester) async {
    api.error = 'boom';
    await pumpCard(tester, const AccountDangerZoneCard());

    await tester.tap(find.text('Destroy identity'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'DESTROY');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(HollowButton, 'Destroy'));
    await tester.pumpAndSettle();

    expect(api.destroys, 1);
    expect(find.text('Destroy your data'), findsOneWidget);
    expect(find.text("Couldn't destroy the data. Try again."), findsOneWidget);
  });
}

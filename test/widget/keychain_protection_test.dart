// Keychain protection on by default (0.12.1): the onboarding phrase step, the
// one-time offer to existing identities, Settings and the key-missing screen.
// What is pinned is what would lock somebody out quietly: a default without a
// confirmed phrase, an offer that shows twice or takes a wrong phrase, and a
// key-missing screen that replaces anything the person did not ask it to.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:hollow/src/ui/dialogs/keychain_protection_dialogs.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/security_section.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/shell/key_missing_dialog.dart';

import '../helpers/test_app.dart';

const _phrase = 'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon abandon abandon art';
const _other = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo '
    'zoo zoo zoo zoo zoo zoo zoo zoo vote';

/// Rust as these screens see it, with every call they make recorded.
class _Api implements RustLibApi {
  final calls = <String>[];
  final settings = <String, String>{};
  bool eligible = true;
  bool encrypted = false;
  bool password = false;
  String? storedPhrase;
  bool keyBack = false;
  bool launchAllowed = true;

  @override
  bool crateApiIdentityAppLockLaunchSecretAllowed() => launchAllowed;

  @override
  Future<bool> crateApiIdentityProtectNewIdentityByDefault(
      {required String phrase}) async {
    calls.add('default:$phrase');
    return true;
  }

  @override
  Future<void> crateApiIdentityEnableOsKeychainProtectionWithPhrase(
      {required String phrase}) async {
    calls.add('enable:$phrase');
    if (phrase != _phrase) {
      throw 'That recovery phrase belongs to a different identity.';
    }
    encrypted = true;
  }

  @override
  Future<void> crateApiIdentityDisableOsKeychainProtection() async {
    calls.add('disable');
    encrypted = false;
  }

  @override
  Future<bool> crateApiIdentityKeychainDefaultEligible() async => eligible;

  @override
  Future<identity_api.ProtectionStatus>
      crateApiIdentityGetIdentityProtectionStatus() async =>
          identity_api.ProtectionStatus(
            isEncrypted: encrypted || password,
            hasPassword: password,
            hasOsKeychain: encrypted,
            osKeychainAvailable: true,
          );

  @override
  Future<String?> crateApiRosterStoredPhraseForUpgrade() async => storedPhrase;

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      settings[key];

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<identity_api.IdentityInfo> crateApiIdentityUnlockIdentity(
      {String? password}) async {
    calls.add('unlock');
    if (!keyBack) {
      throw 'keychain_key_missing: the key that opens this identity is not in '
          "this computer's keychain";
    }
    return const identity_api.IdentityInfo(peerId: 'm', devicePeerId: 'd');
  }

  @override
  Future<bool> crateApiIdentityRecoveryPhraseFitsThisProfile(
      {required String phrase}) async {
    calls.add('fits:$phrase');
    return phrase == _phrase;
  }

  @override
  Future<identity_api.IdentityInfo> crateApiIdentityRestoreIdentityFromMnemonic(
      {required String phrase}) async {
    calls.add('restore:$phrase');
    keyBack = true;
    return const identity_api.IdentityInfo(peerId: 'm', devicePeerId: 'd2');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('unexpected:${invocation.memberName}');
    return super.noSuchMethod(invocation);
  }
}

void main() {
  final api = _Api();
  setUpAll(() {
    RustLib.initMock(api: api);
    // App Lock reads the OS keystore: never the real one from a test.
    FlutterSecureStorage.setMockInitialValues({});
  });
  setUp(() {
    api.calls.clear();
    api.settings.clear();
    api.eligible = true;
    api.encrypted = false;
    api.password = false;
    api.storedPhrase = null;
    api.keyBack = false;
  });

  Future<BuildContext> host(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        navigatorKey: hollowNavigatorKey,
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const SizedBox.expand();
        })),
      ),
    ));
    return context;
  }

  Future<void> typeAskedWords(WidgetTester tester, String phrase,
      {bool wrong = false}) async {
    final words = phrase.split(' ');
    final asked = tester
        .widgetList<Text>(find.byWidgetPredicate(
            (w) => w is Text && RegExp(r'^Word \d+$').hasMatch(w.data ?? '')))
        .map((t) => int.parse(t.data!.split(' ').last))
        .toList();
    final fields = find.byType(TextField);
    for (var i = 0; i < asked.length; i++) {
      await tester.enterText(
          fields.at(i), wrong ? 'wrongword' : words[asked[i] - 1]);
    }
    await tester.pump();
  }

  group('onboarding', () {
    testWidgets('the default runs only once the phrase was typed back',
        (tester) async {
      final context = await host(tester);
      showMnemonicDialog(context, _phrase);
      await tester.pumpAndSettle();

      // Shown, never dismissible, nothing locked yet.
      expect(find.text('Later'), findsNothing);
      expect(api.calls.where((c) => c.startsWith('default')), isEmpty);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Your recovery phrase'), findsOneWidget);

      await tester.tap(find.text("I've written it down"));
      await tester.pumpAndSettle();
      await typeAskedWords(tester, _phrase, wrong: true);
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.text("Those words don't match. Check your copy."),
          findsOneWidget);
      expect(api.calls.where((c) => c.startsWith('default')), isEmpty,
          reason: 'wrong words turned the default on');

      await typeAskedWords(tester, _phrase);
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c.startsWith('default')),
          ['default:$_phrase']);
      expect(find.textContaining('now locked to this computer'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    });
  });

  group('the offer', () {
    testWidgets('is claimed once and only where it applies', (tester) async {
      expect(await claimKeychainOffer(keystorePlatform: false), isFalse,
          reason: 'Linux and phones are never offered');
      expect(api.settings, isEmpty);

      api.eligible = false;
      expect(await claimKeychainOffer(keystorePlatform: true), isFalse,
          reason: 'portable or an override is never offered');
      api.eligible = true;

      api.encrypted = true;
      expect(await claimKeychainOffer(keystorePlatform: true), isFalse,
          reason: 'a password or keychain identity is left alone');
      api.encrypted = false;

      api.storedPhrase = _phrase;
      expect(await claimKeychainOffer(keystorePlatform: true), isFalse,
          reason: 'the stored phrase is confirmed first');
      api.storedPhrase = null;
      expect(api.settings, isEmpty, reason: 'a skipped offer was marked');

      expect(await claimKeychainOffer(keystorePlatform: true), isTrue);
      expect(api.settings[kKeychainOfferShownKey], '1');
      expect(await claimKeychainOffer(keystorePlatform: true), isFalse,
          reason: 'the offer showed twice');
    });

    testWidgets('a wrong phrase is refused on the field and Not now changes '
        'nothing', (tester) async {
      final context = await host(tester);
      final result = showKeychainOfferDialog(context);
      await tester.pumpAndSettle();
      expect(find.text('Lock your identity to this computer?'), findsOneWidget);

      await tester.enterText(find.byType(TextField), _other);
      await tester.pump();
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(find.text("That isn't your recovery phrase. Check each word and "
          'the order.'), findsOneWidget);
      expect(find.text('Lock your identity to this computer?'), findsOneWidget,
          reason: 'a wrong phrase closed the offer');

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(api.calls, ['enable:$_other']);
    });

    testWidgets('the whole phrase turns it on', (tester) async {
      final context = await host(tester);
      final result = showKeychainOfferDialog(context);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField), '  ${_phrase.toUpperCase()} ');
      await tester.pump();
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(api.calls, ['enable:$_phrase']);
    });
  });

  group('the key-missing screen', () {
    testWidgets('Try again replaces nothing and opens once the key is back',
        (tester) async {
      final context = await host(tester);
      final opened = showKeyMissingScreen(context);
      await tester.pumpAndSettle();
      expect(find.text("Hollow can't open your identity"), findsOneWidget);
      expect(find.textContaining('Nothing has been deleted'), findsOneWidget);
      expect(
          ModalRoute.of(tester.element(find.byType(KeyMissingDialog)))!
              .barrierDismissible,
          isFalse,
          reason: 'a click beside the screen would close it');

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text("The key still isn't there, so nothing has changed."),
          findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text("Hollow can't open your identity"), findsOneWidget,
          reason: 'the screen can be dismissed into a half-started app');

      api.keyBack = true;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(await opened, isTrue);
      expect(api.calls, ['unlock', 'unlock'],
          reason: 'something besides unlocking ran');
    });

    testWidgets('a phrase restore takes only a phrase that fits this profile',
        (tester) async {
      final context = await host(tester);
      final opened = showKeyMissingScreen(context);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use recovery phrase'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), _other);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(
          find.text('That phrase belongs to a different identity than the one '
              'on this computer.'),
          findsOneWidget);
      expect(api.calls.where((c) => c.startsWith('restore')), isEmpty,
          reason: "another identity's phrase replaced the files");

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text("Hollow can't open your identity"), findsOneWidget,
          reason: 'cancelling the restore left the screen');

      await tester.tap(find.text('Use recovery phrase'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), _phrase);
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(await opened, isTrue);
      expect(api.calls.where((c) => c.startsWith('restore')),
          ['restore:$_phrase']);
      expect(api.settings['protection_offer_due'], '1',
          reason: 'the restored identity is not offered a lock again');
      expect(api.calls.where((c) => c.startsWith('enable') || c.startsWith('default')),
          isEmpty,
          reason: 'a restore locked the identity on its own');
    });
  });

  group('Settings', () {
    Future<void> pumpSection(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      // A fresh section each time, never the State of the last one.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          duressStatusProvider.overrideWith((ref) async =>
              const identity_api.DuressStatus(
                  enabled: false,
                  scope: 'device',
                  notifyFriends: false,
                  available: false,
                  rebindDue: false)),
        ]),
        child: MaterialApp(
          navigatorKey: hollowNavigatorKey,
          theme: HollowThemeData.dark(),
          home: const Scaffold(
              body: SingleChildScrollView(child: SecurityAppLockSection())),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Finder lockToggle() => find.descendant(
        of: find.ancestor(
            of: find.text('Lock to this computer'),
            matching: find.byType(SettingsSwitchRow)),
        matching: find.byType(HollowToggle));

    // One test: App Lock's service is a singleton whose first read caches a
    // future, and a later test's fake clock would never run its callbacks.
    testWidgets('turns on with the phrase, off after asking once, and shows '
        'only where it applies', (tester) async {
      await pumpSection(tester);
      expect(find.text('Lock to this computer'), findsOneWidget);

      await tester.tap(lockToggle());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), _phrase);
      await tester.pump();
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('enable:$_phrase'));
      expect(tester.widget<HollowToggle>(lockToggle()).value, isTrue);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      await tester.tap(lockToggle());
      await tester.pumpAndSettle();
      expect(find.text('Turn off the lock to this computer?'), findsOneWidget);
      await tester.tap(find.text('Turn off').last);
      await tester.pumpAndSettle();
      expect(api.calls, contains('disable'));
      expect(tester.widget<HollowToggle>(lockToggle()).value, isFalse);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();

      // Where the default does not apply (portable, an override, Linux), it
      // is not offered, but one that is on can still be turned off.
      api.eligible = false;
      await pumpSection(tester);
      expect(find.text('Set password'), findsOneWidget);
      expect(find.text('Lock to this computer'), findsNothing);
      api.encrypted = true;
      await pumpSection(tester);
      expect(find.text('Lock to this computer'), findsOneWidget);

      // A password identity is left alone.
      api.eligible = true;
      api.encrypted = false;
      api.password = true;
      await pumpSection(tester);
      expect(find.text('Lock to this computer'), findsNothing);
      expect(find.text('Ask before Hollow starts'), findsOneWidget);
      SettingsSwitchRow coldStart() => tester.widget<SettingsSwitchRow>(
          find.widgetWithText(SettingsSwitchRow, 'Ask before Hollow starts'));
      expect(coldStart().onChanged, isNotNull);

      // A profile outside the OS's own folder keeps no launch secret, so the
      // prompt is always on and says why.
      api.launchAllowed = false;
      await pumpSection(tester);
      expect(coldStart().value, isTrue);
      expect(coldStart().onChanged, isNull);
      expect(coldStart().subtitle, contains("isn't in Hollow's usual folder"));

      // A 0.12.1 profile here still has its password key cached in the keychain
      // (flags 0x03): the switch shows the silent start and can turn the prompt
      // on.
      api.eligible = false;
      api.password = true;
      api.encrypted = true;
      await pumpSection(tester);
      expect(coldStart().value, isFalse);
      expect(coldStart().onChanged, isNotNull,
          reason: 'disabled, saying "${coldStart().subtitle}"');
      expect(coldStart().subtitle,
          isNot(contains("isn't in Hollow's usual folder")));
    });
  });
}

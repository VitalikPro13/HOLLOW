// The launch around a Welcome phrase restore: Welcome opens on the phrase step
// after a set-aside, and a restore that left the keys unlocked owes the lock
// offer (PHRASE_RESTORE_DESIGN 1.1 step 4, 6.2).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/api/identity.dart';
import 'package:hollow/src/rust/api/recovery.dart';
import 'package:hollow/src/rust/api/roster.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/protection_prompt.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/hollow_shell.dart';

import '../helpers/test_app.dart';

const _phrase = 'abandon ability able about above absent absorb abstract '
    'absurd abuse access accident account accuse achieve acid acoustic '
    'acquire across act action actor actress actual';

class _BootApi implements RustLibApi {
  bool setAside = false;
  int setAsideCleared = 0;
  bool encrypted = false;
  final saved = <String, String>{};
  final restores = <WelcomeRestoreMode>[];

  @override
  Future<bool> crateApiStorageHasIdentity() async => false;

  @override
  Future<void> crateApiStorageMarkLinkThrowaway() async {}

  @override
  Future<IdentityInfo> crateApiIdentityUnlockIdentity({String? password}) =>
      Future.error(StateError('no identity'));

  @override
  Future<bool> crateApiStorageSettleLinkThrowaway() async => false;

  @override
  Future<bool> crateApiStorageHasPendingWipe() async => false;

  @override
  Future<void> crateApiRecoverySettleRelink() async {}

  @override
  Future<void> crateApiIdentitySettleKeychainMove() async {}

  @override
  Future<bool> crateApiStorageHasPendingLink() async => false;

  @override
  Future<String?> crateApiRecoveryRelinkWelcome() async => null;

  String? setAsideRelay;

  @override
  Future<SetAsideWelcome?> crateApiRecoverySetAsideWelcome() async =>
      setAside ? SetAsideWelcome(relay: setAsideRelay) : null;

  @override
  Future<void> crateApiRecoveryClearSetAsideWelcome() async =>
      setAsideCleared++;

  @override
  Future<RestoreOutcome> crateApiIdentityWelcomeRestore({
    required String phrase,
    required WelcomeRestoreMode mode,
    required bool checkKept,
  }) async {
    restores.add(mode);
    return RestoreOutcome.restored(lockedToKeychain: encrypted);
  }

  @override
  Future<ProtectionStatus> crateApiIdentityGetIdentityProtectionStatus() async =>
      ProtectionStatus(
          isEncrypted: encrypted,
          hasPassword: false,
          hasOsKeychain: encrypted,
          osKeychainAvailable: true);

  @override
  Future<void> crateApiStorageSaveSetting(
          {required String key, required String value}) async =>
      saved[key] = value;

  @override
  Future<RosterStatus> crateApiRosterRosterStatus() async => const RosterStatus(
      member: true, protected: true, backupWait: false, devices: []);

  // Anything else the launch asks waits forever.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (_nullAnswers.any(name.contains) ||
        (_bootPastWelcome && name.contains('crateApi'))) {
      return Future<Null>.value(null);
    }
    if (name.contains('crateApi')) {
      return Completer<Never>().future;
    }
    return super.noSuchMethod(invocation);
  }
}

/// Reads and fire-and-forget calls the launch makes after Welcome, answered
/// "nothing here" so a restore reaches the node start.
const _nullAnswers = [
  'crateApiStorageLoadSetting"',
  'crateApiStorageGetAvatar"',
  'crateApiNetworkLogFromDart"',
  'crateApiRecoveryClearRelinkWelcome"',
  'crateApiRosterStoredPhraseForUpgrade"',
  'crateApiRosterWelcomeRestoreState"',
  'crateApiNetworkSetRelayUrl"',
];

final class _NoProfiles extends IOOverrides {
  @override
  File createFile(String path) =>
      _missing.any(path.endsWith) ? _Missing(path) : super.createFile(path);
}

/// Files the launch looks for; real file IO never completes under the test clock.
const _missing = ['profiles.json', 'identity.key', 'custom_background.img'];

class _Missing implements File {
  _Missing(this.path);
  @override
  final String path;
  @override
  bool existsSync() => false;
  @override
  Future<bool> exists() async => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoIdentityYet extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState();

  @override
  Future<void> load() async =>
      state = const IdentityState(peerId: 'restored', isLoaded: true);
}

final _api = _BootApi();
var _bootPastWelcome = false;

Future<void> _launch(WidgetTester tester, FutureOr<void> Function() check) async {
  IOOverrides.global = _NoProfiles();
  addTearDown(() => IOOverrides.global = null);
  // A phone width, so the host draws MobileShell (see tablet_first_run_test).
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        identityProvider.overrideWith(_NoIdentityYet.new),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const HollowShell(),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await check();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<void> _restoreWithNo(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('phrase-branch-admit')));
  await tester.pump(const Duration(milliseconds: 300));
  await _typeAndRestore(tester);
}

Future<void> _typeAndRestore(WidgetTester tester) async {
  await tester.enterText(
      find.descendant(
          of: find.byKey(const ValueKey('welcome-phrase-field')),
          matching: find.byType(EditableText)),
      _phrase);
  await tester.pump();
  await tester.ensureVisible(find.text('Restore'));
  await tester.tap(find.text('Restore'));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: _api));
  setUp(() {
    _bootPastWelcome = false;
    _api
      ..setAside = false
      ..setAsideRelay = null
      ..setAsideCleared = 0
      ..encrypted = false
      ..saved.clear()
      ..restores.clear();
  });

  testWidgets('a restore that left the keys unlocked owes the lock offer, and '
      'the shell opens', (tester) async {
    await _launch(tester, () async {
      await tester.tap(find.text('Agree and continue'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Use your recovery phrase'));
      await tester.tap(find.text('Use your recovery phrase'));
      await tester.pump(const Duration(milliseconds: 300));
      await _restoreWithNo(tester);
      expect(_api.restores, [const WelcomeRestoreMode.admit()]);
      expect(_api.saved[kProtectionOfferDueKey], '1');
      expect(_api.saved[kRecoveryPhraseSavedKey], '1',
          reason: 'the person just typed the words: Home asks for no backup');
      expect(find.byType(MobileShell), findsOneWidget);
      expect(_api.setAsideCleared, 0, reason: 'nothing was set aside');
    });
  });

  testWidgets('a restore the keychain default locked owes no offer',
      (tester) async {
    _api.encrypted = true;
    await _launch(tester, () async {
      await tester.tap(find.text('Agree and continue'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Use your recovery phrase'));
      await tester.tap(find.text('Use your recovery phrase'));
      await tester.pump(const Duration(milliseconds: 300));
      await _restoreWithNo(tester);
      expect(_api.restores, hasLength(1));
      expect(_api.saved.containsKey(kProtectionOfferDueKey), isFalse);
    });
  });

  testWidgets('after a set-aside the launch opens Welcome on the phrase step '
      'and clears the note once', (tester) async {
    _api
      ..setAside = true
      ..setAsideRelay = 'relay.example.org';
    await _launch(tester, () async {
      expect(find.text('Could someone else have your old device?'),
          findsOneWidget);
      expect(find.text('relay.example.org'), findsOneWidget,
          reason: 'the set-aside identity\'s relay, never the default unasked');
      expect(find.textContaining('The identity those words made is set aside'),
          findsOneWidget);
      await _restoreWithNo(tester);
      expect(_api.setAsideCleared, 1);
      expect(find.byType(MobileShell), findsOneWidget);
    });
  });

  testWidgets('a Yes restore asks the restore chooser once the node is up',
      (tester) async {
    await _launch(tester, () async {
      await tester.tap(find.text('Agree and continue'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Use your recovery phrase'));
      await tester.tap(find.text('Use your recovery phrase'));
      await tester.pump(const Duration(milliseconds: 300));
      final container =
          ProviderScope.containerOf(tester.element(find.byType(HollowShell)));
      expect(container.read(restoreChooserAskProvider), isNull);
      // The launch past this point is not under test: it waits from here on.
      container.listen(restoreChooserAskProvider, (_, _) => _bootPastWelcome = false);
      await tester.tap(find.byKey(const ValueKey('phrase-branch-recover')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(
          find.byKey(const ValueKey('last-had-yesterday')));
      await tester.tap(find.byKey(const ValueKey('last-had-yesterday')));
      await tester.pump(const Duration(milliseconds: 300));
      _bootPastWelcome = true;
      await _typeAndRestore(tester);
      expect(_api.restores.single, isA<WelcomeRestoreMode_Recover>());
      // Past the relay status fetch, which gives up after 5 s.
      for (var i = 0; i < 200 && container.read(restoreChooserAskProvider) == null; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(container.read(restoreChooserAskProvider)?.fresh, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    });
  });

  group('phraseRestoreFollowUps', () {
    ({String action, String relayDomain, bool agreedTerms, PhraseRestoreBranch? branch})
        result(String action, [PhraseRestoreBranch? branch]) => (
              action: action,
              relayDomain: 'relay.anonlisten.com',
              agreedTerms: true,
              branch: branch,
            );

    test('only a phrase restore owes anything', () {
      for (final r in [null, result('create_new'), result('restored_backup'),
          result('link_device')]) {
        expect(phraseRestoreFollowUps(r),
            (offerLock: false, askChooser: false, phraseSaved: false));
      }
    });

    test('No owes the lock offer, Yes the restore chooser too, and both '
        'count the typed phrase as saved', () {
      expect(
          phraseRestoreFollowUps(
              result('restored_phrase', PhraseRestoreBranch.admit)),
          (offerLock: true, askChooser: false, phraseSaved: true));
      expect(
          phraseRestoreFollowUps(
              result('restored_phrase', PhraseRestoreBranch.recover)),
          (offerLock: true, askChooser: true, phraseSaved: true));
    });
  });
}

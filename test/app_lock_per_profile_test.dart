// B4: App Lock's entries belong to ONE profile. Two profiles never read or
// overwrite each other's secret, the global entries from before 0.12.2 move once
// into the profile whose identity they open (never guessed into another), and a
// wipe takes that profile's entries and only those.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';

class _MapStore implements AppLockStore {
  final items = <String, String>{};
  @override
  Future<String?> read(String key) async => items[key];
  @override
  Future<void> write(String key, String value) async => items[key] = value;
  @override
  Future<void> delete(String key) async => items.remove(key);
  @override
  Future<Map<String, String>> readAll() async => Map.of(items);
}

/// One profile's view of the machine: its id file and what its identity opens.
class _Profile {
  String? id;
  final String idOnCreate;
  final Set<String> opens;
  bool hasIdentity;
  int checks = 0;
  _Profile(this.idOnCreate, {this.opens = const {}, this.hasIdentity = true});

  /// A launch of the app in this profile.
  AppLockService launch(_MapStore store, {bool oneProfile = false}) =>
      AppLockService.debugReplace(
        store: store,
        profileId: (create) => id ??= create ? idOnCreate : null,
        opensIdentity: (secret) async {
          checks++;
          if (!hasIdentity) throw 'No identity file found';
          return opens.contains(secret);
        },
        oneProfile: oneProfile,
      );
}

const _legacyLaunch = 'hollow_app_lock_launch_secret';
const _legacyBio = 'hollow_app_lock_secret';
const _legacyType = 'hollow_app_lock_type';

void main() {
  test('two profiles never see each other\'s secret', () async {
    final store = _MapStore();
    final a = _Profile('aaaaaaaaaaaaaaaa');
    final b = _Profile('bbbbbbbbbbbbbbbb');

    final inA = a.launch(store);
    await inA.storeLaunchSecret('111111');
    await inA.enableBiometric('111111');
    await inA.setLockType('pin');

    final inB = b.launch(store);
    expect(await inB.readLaunchSecret(), isNull);
    expect(await inB.isBiometricEnabled(), isFalse);
    expect(await inB.getLockType(), isNull);
    await inB.storeLaunchSecret('222222');

    final backInA = a.launch(store);
    expect(await backInA.readLaunchSecret(), '111111', reason: 'b clobbered a');
    expect(await b.launch(store).readLaunchSecret(), '222222');
  });

  test('legacy entries move once into the profile they open, never into another',
      () async {
    final store = _MapStore()
      ..items[_legacyLaunch] = '424242'
      ..items[_legacyBio] = '424242'
      ..items[_legacyType] = 'pin';
    final a = _Profile('aaaaaaaaaaaaaaaa', opens: {'424242'});
    final b = _Profile('bbbbbbbbbbbbbbbb');

    // b launches first: the secret does not open b, so b gets nothing.
    final inB = b.launch(store);
    expect(await inB.readLaunchSecret(), isNull);
    expect(await inB.getLockType(), isNull, reason: 'a bare marker was guessed into b');
    expect(store.items[_legacyLaunch], '424242', reason: 'b took entries it does not own');
    final bChecks = b.checks;
    await b.launch(store).readLaunchSecret();
    expect(b.checks, bChecks, reason: 'b judged the same entries twice');

    // a owns them: they move, and the global copies go.
    final inA = a.launch(store);
    expect(await inA.readLaunchSecret(), '424242');
    expect(await inA.isBiometricEnabled(), isTrue);
    expect(await inA.getLockType(), 'pin');
    expect(store.items.keys.where((k) => !k.contains('.')), isEmpty,
        reason: 'the legacy entries stayed global');

    final checks = a.checks;
    expect(await a.launch(store).readLaunchSecret(), '424242');
    expect(a.checks, checks, reason: 'the migration ran twice');
    expect(await b.launch(store).readLaunchSecret(), isNull);
  });

  test('a secret that opens nothing on a phone is dropped, its marker kept',
      () async {
    final store = _MapStore()
      ..items[_legacyLaunch] = 'stale1'
      ..items[_legacyType] = 'pin';
    final phone = _Profile('cccccccccccccccc');
    final inPhone = phone.launch(store, oneProfile: true);
    expect(await inPhone.readLaunchSecret(), isNull);
    expect(await inPhone.getLockType(), 'pin');
    expect(store.items.containsKey(_legacyLaunch), isFalse);
  });

  test('with no identity yet nothing moves, and the next launch decides',
      () async {
    final store = _MapStore()..items[_legacyLaunch] = '424242';
    final p = _Profile('dddddddddddddddd', opens: {'424242'}, hasIdentity: false);
    expect(await p.launch(store).readLaunchSecret(), isNull);
    expect(store.items[_legacyLaunch], '424242');
    p.hasIdentity = true;
    expect(await p.launch(store).readLaunchSecret(), '424242');
  });

  test('a wipe takes this profile\'s entries and only those', () async {
    final store = _MapStore();
    final a = _Profile('aaaaaaaaaaaaaaaa');
    final b = _Profile('bbbbbbbbbbbbbbbb');
    await b.launch(store).storeLaunchSecret('222222');
    final inA = a.launch(store);
    await inA.storeLaunchSecret('111111');
    await inA.setLockType('pin');
    await inA.markLongerPinAsked();
    // The wipe deleted the id file before the clean-up runs.
    a.id = null;
    await inA.clearAll();
    expect(store.items.keys.where((k) => k.endsWith('.aaaaaaaaaaaaaaaa')), isEmpty);
    expect(await b.launch(store).readLaunchSecret(), '222222');

    // Erasing another profile from the list names it by its id.
    await a.launch(store).clearProfile('bbbbbbbbbbbbbbbb');
    expect(await b.launch(store).readLaunchSecret(), isNull);
  });

  group('waits after missed tries (B5)', () {
    test('Rust\'s wait is read and said in plain words', () {
      expect(appLockWaitFrom('too_many_attempts: 30'), 30);
      expect(appLockWaitFrom('Wrong password or corrupted identity file'), isNull);
      expect(appLockWaitText(30), 'Too many tries. You can try again in 30 seconds.');
      expect(appLockWaitText(1), 'Too many tries. You can try again in 1 second.');
      expect(appLockWaitText(60), 'Too many tries. You can try again in 1 minute.');
      expect(appLockWaitText(299), 'Too many tries. You can try again in 5 minutes.');
      expect(appLockWaitText(3600), 'Too many tries. You can try again in 60 minutes.');
      for (final s in [1, 30, 61, 900, 3600]) {
        expect(appLockWaitText(s), isNot(contains('—')));
      }
    });

    test('a Settings prompt shows the wait, not a generic failure', () {
      expect(friendlyError('too_many_attempts: 900'),
          'Too many tries. You can try again in 15 minutes.');
      expect(friendlyError('hardware_key_missing: gone'),
          contains('recovery phrase'));
    });
  });

  // The Rust side paces `unlockIdentity` and only that; a secret the keystore
  // handed back must use the stored-secret call, or a relaunch resets the count.
  test('stored secrets unlock through the call that is never paced', () {
    final shell = File('lib/src/ui/shell/hollow_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(shell, isNot(contains('unlockIdentity(password: stored)')));
    expect(shell, isNot(contains('unlockIdentity(password: secret)')));
    expect(
        RegExp(r'unlockIdentityWithStoredSecret\(\s*secret: stored, personPresent: false\)')
            .hasMatch(shell),
        isTrue);
    expect(
        RegExp(r'unlockIdentityWithStoredSecret\(\s*secret: secret, personPresent: true\)')
            .hasMatch(shell),
        isTrue);
  });

  // A lost hardware key (a reset keystore, a restore onto another phone, the iOS
  // app moved to a new Apple team): Rust refuses with `hardware_key_missing` and
  // deletes nothing; every unlock path sends the person to the recovery phrase.
  test('a lost hardware key leads to the recovery phrase, from every unlock path',
      () {
    expect(isHardwareKeyMissing('hardware_key_missing: the key that opens'), isTrue);
    expect(isHardwareKeyMissing('Wrong password or corrupted identity file'), isFalse);
    final shell = File('lib/src/ui/shell/hollow_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(
        RegExp(r'isHardwareKeyMissing\(e\)\) return _showHardwareKeyMissingDialog\(\)')
            .allMatches(shell)
            .length,
        2,
        reason: 'the launch secret and the typed PIN');
    expect(shell, contains('if (hardwareMissing) return _showHardwareKeyMissingDialog();'));
    final dialog = shell.substring(shell.indexOf('Future<bool> _showHardwareKeyMissingDialog'));
    expect(dialog.substring(0, 1500), contains('RecoveryPhraseDialog('));
    expect(dialog.substring(0, 1500), contains('Nothing has been deleted.'));
  });

  // A wipe the push fetch, the NSE or a boot wipe finished deletes app_lock.id
  // before any Dart in a NEW process read it; clearing the traces must still
  // find the PIN in secure storage.
  test('a wipe finished outside this process still clears the App Lock secrets',
      () async {
    final store = _MapStore();
    String? idFile = 'aaaaaaaaaaaaaaaa';

    final before = AppLockService.debugReplace(
      store: store,
      profileId: (create) => idFile,
      opensIdentity: (_) async => true,
      oneProfile: true,
    );
    await before.setLockType('pin');
    await before.storeLaunchSecret('482916');
    await before.enableBiometric('482916');
    await before.markDuressRebindAsked();

    // The push fetch ran a remote kill: the root is swept, app_lock.id with it.
    idFile = null;

    final after = AppLockService.debugReplace(
      store: store,
      profileId: (create) => idFile ??= create ? 'bbbbbbbbbbbbbbbb' : null,
      opensIdentity: (_) async => throw 'No identity file found',
      oneProfile: true,
    );
    await after.clearAll();

    expect(store.items.values, isNot(contains('482916')),
        reason: 'the wiped identity\'s PIN is still in secure storage: '
            '${store.items}');
    expect(store.items, isEmpty, reason: 'every marker of the gone profile goes');
  });

  test('a profile\'s clean-up takes its own markers and never another\'s',
      () async {
    final store = _MapStore();
    // An entry from before 0.12.2 neither profile's identity opens: each marks
    // it judged.
    store.items[_legacyType] = 'pin';
    final a = _Profile('aaaaaaaaaaaaaaaa');
    final b = _Profile('bbbbbbbbbbbbbbbb');
    final inA = a.launch(store);
    await inA.storeLaunchSecret('111111');
    await inA.markDuressRebindAsked();
    final inB = b.launch(store);
    await inB.storeLaunchSecret('222222');
    await inB.markDuressRebindAsked();

    // On a desktop (several profiles) clearing A leaves B whole.
    await a.launch(store).clearAll();
    expect(store.items.keys.where((k) => k.endsWith('.aaaaaaaaaaaaaaaa')), isEmpty);
    expect(await b.launch(store).readLaunchSecret(), '222222');
    expect(await b.launch(store).duressRebindAsked(), isTrue);
    expect(store.items['hollow_app_lock_legacy_checked.bbbbbbbbbbbbbbbb'], '1');
  });

  test('a busy keystore is not a lost key, nor a wrong secret', () {
    const busy = 'hardware_key_busy: this device\'s secure hardware did not answer this time';
    expect(isHardwareKeyBusy(busy), isTrue);
    expect(isHardwareKeyMissing(busy), isFalse);
    expect(isWrongSecret(busy), isFalse);
    expect(isWrongSecret('Wrong password or corrupted identity file'), isTrue);
    final shell = File('lib/src/ui/shell/hollow_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(RegExp(r'isHardwareKeyBusy\(e\)').allMatches(shell).length, 3,
        reason: 'the launch secret, the biometric and the typed PIN');
    // A stored copy is dropped only when the secret itself was wrong.
    expect(shell, contains('if (isWrongSecret(e)) await appLock.disableBiometric();'));
    expect(shell, contains('} else if (isWrongSecret(e)) {\n              // Changed through recovery'));
    final busyScreen = shell.substring(shell.indexOf('Future<bool?> _whileHardwareBusy'));
    expect(busyScreen.substring(0, 1200), contains('HardwareKeyBusyDialog('));
    expect(busyScreen.substring(0, 1200), contains('withTypedSecret(retry)'),
        reason: 'a duress code typed into the retry still ends the session');
  });
}

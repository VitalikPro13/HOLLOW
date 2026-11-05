// HOL-SEC-187: on iOS every App Lock entry lives in the keys app group, which an
// app transfer keeps; builds before 0.14 wrote the app-ID group, which a team change
// loses. The move copies, reads back and only then deletes, every call names its
// group, and a delete of the old entry never takes the new one.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';

const _plugin = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _keys = 'group.com.anonlisten.hollow.keys';
const _appId = 'ABCDE12345.com.anonlisten.hollow';
const _id = '0123456789abcdef';

/// The keychain as iOS keeps it: an item's identity is (group, key); the class is
/// part of a read's match; a query naming no group matches every group.
final _items = <(String, String), ({String value, String accessibility})>{};
final _calls = <String>[];
var _keysRefused = false;
var _keysDropWrites = false;
var _appIdDeleteFails = false;
var _keysBusy = 0;
String? _dieAfter;
// The process ends after this call: every later call fails until the next start.
int? _killAfterCall;
var _dead = false;
// Writes of these keys report success and keep nothing.
final _dropWritesOf = <String>{};
// These calls fail once (-25308) and change nothing.
final _failOnce = <String>{};
// Runs after the nth call matching a string, as another process would.
({String call, int nth, void Function() then})? _afterCall;
// This call waits for [gate] before it runs; [reached] completes when it is held.
({String call, Completer<void> reached, Completer<void> gate})? _hold;

String _classOf(Map<Object?, Object?> args) =>
    ((args['options'] as Map?)?['accessibility'] as String?) ?? 'unlocked';
String? _groupOf(Map<Object?, Object?> args) =>
    (args['options'] as Map?)?['groupId'] as String?;

Iterable<(String, String)> _matching(String? group, String? key) => _items.keys
    .where((k) => (group == null || k.$1 == group) && (key == null || k.$2 == key))
    .toList();

void _mockKeychain() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('hollow/keychain_groups'),
      (call) async => {'keys': _keys, 'appId': _appId});
  messenger.setMockMethodCallHandler(_plugin, (call) async {
    final args = call.arguments as Map<Object?, Object?>;
    final key = args['key'] as String?;
    final group = _groupOf(args);
    if (_dead) throw PlatformException(code: 'dead', message: 'no process');
    final named = '${call.method} ${group ?? 'ANY'} ${key ?? ''}';
    final held = _hold;
    if (held != null && held.call == named) {
      _hold = null;
      held.reached.complete();
      await held.gate.future;
    }
    _calls.add(named);
    if (_failOnce.remove(named)) {
      throw PlatformException(
          code: 'Unexpected security result code',
          message: 'Code: -25308, Message: interaction not allowed',
          details: -25308);
    }
    if (group == _keys && _keysRefused) {
      throw PlatformException(
          code: 'Unexpected security result code',
          message: 'Code: -34018, Message: missing entitlement',
          details: -34018);
    }
    if (group == _keys && _keysBusy > 0) {
      _keysBusy--;
      throw PlatformException(
          code: 'Unexpected security result code',
          message: 'Code: -25308, Message: interaction not allowed',
          details: -25308);
    }
    Object? answer;
    switch (call.method) {
      case 'read':
        final hit = _matching(group, key)
            .map((k) => _items[k]!)
            .where((i) => i.accessibility == _classOf(args));
        answer = hit.isEmpty ? null : hit.first.value;
      case 'readAll':
        answer = {
          for (final k in _matching(group, null))
            if (_items[k]!.accessibility == _classOf(args)) k.$2: _items[k]!.value,
        };
      case 'delete':
        if (group == _appId && _appIdDeleteFails) {
          throw PlatformException(code: 'Code: -25308', message: 'busy');
        }
        for (final k in _matching(group, key)) {
          _items.remove(k);
        }
      case 'write':
        if (group == _keys && _keysDropWrites && key != 'hollow_app_lock_group_probe') {
          break;
        }
        if (_dropWritesOf.contains(key)) break;
        // The plugin looks the item up WITH its class, misses one of another
        // class, and adds: the item's identity has no class, so the add collides.
        final there = _items[(group ?? _appId, key!)];
        if (there != null && there.accessibility != _classOf(args)) {
          throw PlatformException(
              code: 'Unexpected security result code',
              message: 'Code: -25299, Message: duplicate item',
              details: -25299);
        }
        _items[(group ?? _appId, key)] =
            (value: args['value'] as String, accessibility: _classOf(args));
    }
    final hook = _afterCall;
    if (hook != null &&
        hook.call == named &&
        _calls.where((c) => c == named).length == hook.nth) {
      _afterCall = null;
      hook.then();
    }
    if (_killAfterCall != null && _calls.length == _killAfterCall) {
      _dead = true;
      throw PlatformException(code: 'died', message: 'the app stopped here');
    }
    if (_dieAfter != null && '${call.method} ${group ?? 'ANY'} $key' == _dieAfter) {
      _dieAfter = null;
      throw PlatformException(code: 'died', message: 'the app stopped here');
    }
    return answer;
  });
}

AppLockService _service() => AppLockService.debugReplace(
      store: SecureAppLockStore(),
      profileId: (_) => _id,
      opensIdentity: (_) async => true,
      oneProfile: true,
    );

void _oldBuildWrote() {
  _items[(_appId, 'hollow_app_lock_type.$_id')] =
      (value: 'pin', accessibility: 'unlocked_this_device');
  _items[(_appId, 'hollow_app_lock_launch_secret.$_id')] =
      (value: '482916', accessibility: 'unlocked_this_device');
  _items[(_appId, 'hollow_app_lock_secret.$_id')] =
      (value: '482916', accessibility: 'unlocked');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    _items.clear();
    _calls.clear();
    _keysRefused = false;
    _keysDropWrites = false;
    _appIdDeleteFails = false;
    _keysBusy = 0;
    _dieAfter = null;
    _killAfterCall = null;
    _dead = false;
    _dropWritesOf.clear();
    _failOnce.clear();
    _afterCall = null;
    _hold = null;
    _mockKeychain();
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('app lock entries move into the keys group and survive a cut-short move',
      () async {
    _oldBuildWrote();
    // The app stops after the first copy landed, before its old entry went.
    _dieAfter = 'write $_keys hollow_app_lock_type.$_id';
    final first = _service();
    expect(await first.readLaunchSecret(), '482916');
    expect(_items.keys.where((k) => k.$1 == _appId), isNotEmpty);

    final second = _service();
    expect(await second.readLaunchSecret(), '482916');
    expect(await second.getLockType(), 'pin');
    expect(await second.isBiometricEnabled(), isTrue);
    expect(_items.keys.where((k) => k.$1 == _appId), isEmpty,
        reason: 'an entry stayed in the group a team change loses');
    expect(
        _items.entries
            .where((e) => e.key.$1 == _keys)
            .map((e) => e.value.accessibility),
        everyElement('unlocked_this_device'));
  });

  test('never deletes an old entry before its copy reads back', () async {
    _oldBuildWrote();
    final reads = <String>[];
    for (final c in _calls) {
      reads.add(c);
    }
    await _service().readLaunchSecret();
    for (final key in [
      'hollow_app_lock_type.$_id',
      'hollow_app_lock_launch_secret.$_id',
      'hollow_app_lock_secret.$_id',
    ]) {
      final delete = _calls.indexOf('delete $_appId $key');
      final readBack = _calls.lastIndexWhere(
          (c) => c == 'read $_keys $key', delete == -1 ? _calls.length - 1 : delete);
      expect(delete, isNot(-1), reason: '$key never left the app-ID group');
      expect(readBack, allOf(isNot(-1), lessThan(delete)),
          reason: '$key was deleted before its copy read back');
    }
  });

  test('a copy that does not read back keeps the old entry', () async {
    _oldBuildWrote();
    _keysDropWrites = true;
    final appLock = _service();
    expect(await appLock.readLaunchSecret(), '482916');
    expect(_items.keys.where((k) => k.$1 == _appId).length, 3,
        reason: 'an entry left before its copy was there');
  });

  test('while both groups hold an entry, the keys group answers', () async {
    _oldBuildWrote();
    _appIdDeleteFails = true;
    _items[(_keys, 'hollow_app_lock_type.$_id')] =
        (value: 'password', accessibility: 'unlocked_this_device');
    expect(await _service().getLockType(), 'password');
  });

  test('a delete of the old entry leaves the new one', () async {
    _oldBuildWrote();
    _items[(_keys, 'hollow_app_lock_type.$_id')] =
        (value: 'password', accessibility: 'unlocked_this_device');
    final appLock = _service();
    expect(await appLock.getLockType(), 'password',
        reason: 'the keys group is read first');
    expect(_items[(_keys, 'hollow_app_lock_type.$_id')]?.value, 'password');
    expect(_items.containsKey((_appId, 'hollow_app_lock_type.$_id')), isFalse);
  });

  test('every call names a group, and a clear deletes in both', () async {
    _oldBuildWrote();
    final appLock = _service();
    await appLock.readLaunchSecret();
    _items[(_appId, 'hollow_app_lock_secret.$_id')] =
        (value: 'stale', accessibility: 'unlocked_this_device');
    await appLock.clearAll();
    expect(_calls.where((c) => c.contains(' ANY ')), isEmpty,
        reason: 'an unnamed query matches every group');
    expect(_items.keys.where((k) => k.$2.endsWith(_id)), isEmpty);
  });

  test('a build without the keys group keeps its entries in the app-ID group',
      () async {
    _keysRefused = true;
    _oldBuildWrote();
    final appLock = _service();
    expect(await appLock.readLaunchSecret(), '482916');
    await appLock.storeLaunchSecret('593104');
    expect(await appLock.readLaunchSecret(), '593104');
    expect(_items[(_appId, 'hollow_app_lock_launch_secret.$_id')]?.value, '593104');
  });

  test('a keychain busy once is asked again, never parked in the app-ID group',
      () async {
    final store = SecureAppLockStore();
    _keysBusy = 1;
    await store.write('hollow_app_lock_type.$_id', 'pin');
    expect(_items.containsKey((_appId, 'hollow_app_lock_type.$_id')), isTrue);
    await store.write('hollow_app_lock_launch_secret.$_id', '482916');
    expect(_items.containsKey((_keys, 'hollow_app_lock_launch_secret.$_id')),
        isTrue,
        reason: 'one busy answer kept every later entry out of the keys group');
  });

  test('a missing entitlement is asked once per process', () async {
    final store = SecureAppLockStore();
    _keysRefused = true;
    await store.write('hollow_app_lock_type.$_id', 'pin');
    _calls.clear();
    await store.write('hollow_app_lock_launch_secret.$_id', '482916');
    expect(_calls.where((c) => c.contains('hollow_app_lock_group_probe')),
        isEmpty);
    expect(_items.containsKey((_appId, 'hollow_app_lock_launch_secret.$_id')),
        isTrue);
  });

  test('macOS reads the launch secret only after the bundle check passed',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final store = _MemoryStore()
      ..entries['hollow_app_lock_launch_secret.$_id'] = '482916';
    AppLockService service(bool verified) => AppLockService.debugReplace(
        store: store,
        profileId: (_) => _id,
        opensIdentity: (_) async => true,
        sealVerified: verified);
    expect(await service(false).readLaunchSecret(), isNull);
    expect(store.entries, isNotEmpty, reason: 'an unverified start deleted it');
    expect(await service(true).readLaunchSecret(), '482916');
  });

  for (final platform in ['macOS', 'iOS without the keys group']) {
    test('a class migration cut short keeps the entry ($platform)', () async {
      const key = 'hollow_app_lock_secret';
      final group = platform == 'macOS' ? null : _appId;
      void setUpPlatform() {
        debugDefaultTargetPlatformOverride =
            platform == 'macOS' ? TargetPlatform.macOS : TargetPlatform.iOS;
        _keysRefused = platform != 'macOS';
        _items
          ..clear()
          ..[(_appId, key)] = (value: '482916', accessibility: 'unlocked');
        _calls.clear();
        _dead = false;
      }

      setUpPlatform();
      await SecureAppLockStore().migrateAccessibility([key]);
      final steps = _calls.length;
      expect(_items[(_appId, key)],
          (value: '482916', accessibility: 'unlocked_this_device'));
      expect(_items.keys.where((k) => k.$2 != key), isEmpty,
          reason: 'a finished migration left a copy behind');

      for (var at = 1; at <= steps; at++) {
        setUpPlatform();
        _killAfterCall = at;
        await SecureAppLockStore().migrateAccessibility([key]);
        _killAfterCall = null;
        _dead = false;
        final next = SecureAppLockStore();
        await next.migrateAccessibility([key]);
        expect(_items[(_appId, key)],
            (value: '482916', accessibility: 'unlocked_this_device'),
            reason: 'the app stopped after call $at: ${_calls.take(at).last}');
        expect(await next.read(key), '482916');
        expect(_items.keys.where((k) => k.$2 != key), isEmpty,
            reason: 'a copy outlived the next start (stopped after call $at)');
        expect(group == null || _items.keys.every((k) => k.$1 == group), isTrue);
      }
    });
  }

  test('a re-classed entry that does not read back keeps the old one', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const key = 'hollow_app_lock_secret';
    for (final dropped in ['hollow_app_lock_reclass.$key', key]) {
      _items
        ..clear()
        ..[(_appId, key)] = (value: '482916', accessibility: 'unlocked');
      _dropWritesOf
        ..clear()
        ..add(dropped);
      await SecureAppLockStore().migrateAccessibility([key]);
      expect(_items.values.map((i) => i.value), contains('482916'),
          reason: 'a write of $dropped that kept nothing cost the entry');
      _dropWritesOf.clear();
      await SecureAppLockStore().migrateAccessibility([key]);
      expect(_items[(_appId, key)],
          (value: '482916', accessibility: 'unlocked_this_device'),
          reason: 'the next start did not finish after $dropped was dropped');
      expect(_items.length, 1);
    }
  });

  for (final platform in ['macOS', 'iOS']) {
    test('a scoped old-class entry is re-classed without the keys group ($platform)',
        () async {
      debugDefaultTargetPlatformOverride =
          platform == 'macOS' ? TargetPlatform.macOS : TargetPlatform.iOS;
      _keysRefused = true;
      _items[(_appId, 'hollow_app_lock_secret.$_id')] =
          (value: '482916', accessibility: 'unlocked');
      final appLock = _service();
      await appLock.getLockType();
      expect(_items[(_appId, 'hollow_app_lock_secret.$_id')],
          (value: '482916', accessibility: 'unlocked_this_device'));
      expect(_items.length, 1, reason: 'a staged copy outlived the migration');
    });
  }

  test('a staged copy dies with an App Lock turn-off', () async {
    _keysRefused = true;
    _items[(_appId, 'hollow_app_lock_type.$_id')] =
        (value: 'pin', accessibility: 'unlocked_this_device');
    _items[(_appId, 'hollow_app_lock_secret.$_id')] =
        (value: '482916', accessibility: 'unlocked');
    _items[(_appId, 'hollow_app_lock_launch_secret.$_id')] =
        (value: '482916', accessibility: 'unlocked');
    // One busy answer during the class migration (the delete of the old item).
    _appIdDeleteFails = true;
    final a = _service();
    await a.getLockType();
    _appIdDeleteFails = false;
    // The person turns App Lock off in Settings.
    await a.clearAll();
    expect(_items.values.map((i) => i.value), isNot(contains('482916')),
        reason: 'a secret outlived the turn-off: ${_items.keys}');
    final b = _service();
    expect(await b.isBiometricEnabled(), isFalse,
        reason: 'the next start brought the biometric secret back');
  });

  test('a migration killed mid-way leaves no secret past a wipe',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const key = 'hollow_app_lock_launch_secret.$_id';
    _items[(_appId, key)] = (value: '482916', accessibility: 'unlocked');
    // Stop right after the staged copy was written.
    final store = SecureAppLockStore();
    await store.migrateAccessibility([key]);
    final stageWrite = _calls
            .indexOf('write ANY hollow_app_lock_reclass.$key') +
        1;
    _items
      ..clear()
      ..[(_appId, key)] = (value: '482916', accessibility: 'unlocked');
    _calls.clear();
    _killAfterCall = stageWrite;
    await SecureAppLockStore().migrateAccessibility([key]);
    _killAfterCall = null;
    _dead = false;
    // A wipe the push fetch ran removed the identity and its profile id; the
    // next launch clears what the gone identity left.
    _items.remove((_appId, key));
    final next = AppLockService.debugReplace(
      store: SecureAppLockStore(),
      profileId: (_) => null,
      opensIdentity: (_) async => false,
      oneProfile: true,
    );
    await next.clearAll();
    await next.getLockType();
    expect(_items.values.map((i) => i.value), isNot(contains('482916')),
        reason: 'the gone identity\'s secret is still in the keychain: '
            '${_items.keys}');
  });

  test('erasing another profile takes its staged copy too', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const other = 'fedcba9876543210';
    _items[(_appId, 'hollow_app_lock_reclass.hollow_app_lock_launch_secret.$other')] =
        (value: '482916', accessibility: 'unlocked_this_device');
    _items[(_appId, 'hollow_app_lock_launch_secret.$other')] =
        (value: '482916', accessibility: 'unlocked');
    final appLock = AppLockService.debugReplace(
      store: SecureAppLockStore(),
      profileId: (_) => _id,
      opensIdentity: (_) async => true,
    );
    await appLock.clearProfile(other);
    expect(_items.values.map((i) => i.value), isNot(contains('482916')),
        reason: 'left: ${_items.keys}');
  });


  test('a failed old-item delete leaves no secret past a turn-off (macOS)',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const key = 'hollow_app_lock_secret.$_id';
    _items[(_appId, key)] = (value: '482916', accessibility: 'unlocked');
    _failOnce.add('delete ANY $key');
    final appLock = _service();
    await appLock.getLockType();
    await appLock.clearAll();
    expect(_items.values.map((i) => i.value), isNot(contains('482916')),
        reason: 'left: ${_items.keys}');
    await _service().getLockType();
    expect(_items.values.map((i) => i.value), isNot(contains('482916')),
        reason: 'the next start brought it back: ${_items.keys}');
  });

  test('a second process finishing the migration first keeps its entry (macOS)',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const key = 'hollow_app_lock_secret';
    const stage = 'hollow_app_lock_reclass.$key';
    _items[(_appId, key)] = (value: '482916', accessibility: 'unlocked');
    // Right after this process read its staged copy back, another one finishes
    // the same migration: its entry is in, its staged copy gone.
    _afterCall = (
      call: 'read ANY $stage',
      nth: 2,
      then: () {
        _items
          ..remove((_appId, stage))
          ..[(_appId, key)] =
              (value: '482916', accessibility: 'unlocked_this_device');
      },
    );
    await SecureAppLockStore().migrateAccessibility([key]);
    expect(_afterCall, isNull, reason: 'the interleaving never happened');
    expect(_items[(_appId, key)],
        (value: '482916', accessibility: 'unlocked_this_device'),
        reason: 'the other process\'s entry was deleted');
  });

  for (final clear in ['clearAll', 'clearProfile']) {
    test('a $clear during the migration leaves nothing behind (macOS)',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      const key = 'hollow_app_lock_secret.$_id';
      _items[(_appId, key)] = (value: '482916', accessibility: 'unlocked');
      final appLock = _service();
      // The migration is about to write the entry back from its staged copy
      // when the person turns App Lock off.
      final hold = (
        call: 'write ANY $key',
        reached: Completer<void>(),
        gate: Completer<void>()
      );
      _hold = hold;
      final reading = appLock.getLockType();
      await hold.reached.future;
      final clearing =
          clear == 'clearAll' ? appLock.clearAll() : appLock.clearProfile(_id);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      hold.gate.complete();
      await reading;
      await clearing;
      expect(_items.values.map((i) => i.value), isNot(contains('482916')),
          reason: 'left: ${_items.keys}');
    });
  }

  test('a turn-off during the first adoption of the old entries leaves none',
      () async {
    _items[(_appId, 'hollow_app_lock_secret')] =
        (value: '482916', accessibility: 'unlocked_this_device');
    String? made;
    final judging = Completer<void>();
    final judged = Completer<void>();
    final appLock = AppLockService.debugReplace(
      store: SecureAppLockStore(),
      profileId: (create) => made ??= create ? _id : null,
      opensIdentity: (_) async {
        if (!judging.isCompleted) judging.complete();
        await judged.future;
        return true;
      },
      oneProfile: true,
    );
    final reading = appLock.getLockType();
    await judging.future;
    final clearing = appLock.clearAll();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    judged.complete();
    await reading;
    await clearing;
    expect(_items.values.map((i) => i.value), isNot(contains('482916')),
        reason: 'left: ${_items.keys}');
  });

  test('the duress transfer note has its own marker', () async {
    final appLock = _service();
    await appLock.markDuressRebindAsked();
    expect(await appLock.duressTransferAsked(), isFalse,
        reason: 'the 0.12.2 note must not silence the transfer note');
    await appLock.markDuressTransferAsked();
    expect(await appLock.duressTransferAsked(), isTrue);
    await appLock.clearAll();
    expect(await appLock.duressTransferAsked(), isFalse,
        reason: 'a wipe keeps the marker');
  });
}

class _MemoryStore implements AppLockStore {
  final entries = <String, String>{};
  @override
  Future<String?> read(String key) async => entries[key];
  @override
  Future<void> write(String key, String value) async => entries[key] = value;
  @override
  Future<void> delete(String key) async => entries.remove(key);
  @override
  Future<Map<String, String>> readAll() async => Map.of(entries);
}

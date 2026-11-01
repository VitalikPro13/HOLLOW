// HOL-SEC-187: on iOS every App Lock entry lives in the keys app group, which an
// app transfer keeps; builds before 0.14 wrote the app-ID group, which a team change
// loses. The move copies, reads back and only then deletes, every call names its
// group, and a delete of the old entry never takes the new one.
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
    _calls.add('${call.method} ${group ?? 'ANY'} ${key ?? ''}');
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
        _items[(group ?? _appId, key!)] =
            (value: args['value'] as String, accessibility: _classOf(args));
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

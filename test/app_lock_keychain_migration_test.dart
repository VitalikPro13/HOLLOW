// C-RP-03 / C-LOCAL-17: App Lock's keychain items move to a this-device-only
// class, so they never travel in a backup. An item saved under the old class
// must survive the move: losing the launch secret or the biometric copy would
// cost the person their silent start or their Face ID unlock.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// The keychain as iOS keeps it: the class is part of the match, not of the
/// item's identity, so an add over an item of another class is refused.
final _items = <String, ({String value, String accessibility})>{};

String _classOf(Map<Object?, Object?> args) =>
    ((args['options'] as Map?)?['accessibility'] as String?) ?? 'unlocked';

void _mockKeychain() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    final args = call.arguments as Map<Object?, Object?>;
    final key = args['key'] as String?;
    final item = key == null ? null : _items[key];
    switch (call.method) {
      case 'read':
        return item != null && item.accessibility == _classOf(args)
            ? item.value
            : null;
      case 'containsKey':
        return item != null && item.accessibility == _classOf(args);
      case 'delete':
        _items.remove(key);
        return null;
      case 'write':
        if (item != null && item.accessibility != _classOf(args)) {
          throw PlatformException(code: 'Code: -25299', message: 'duplicate');
        }
        _items[key!] = (
          value: args['value'] as String,
          accessibility: _classOf(args),
        );
        return null;
    }
    return null;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('items saved under the old class move over and keep working', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    _mockKeychain();
    for (final e in {
      'hollow_app_lock_type': 'pin',
      'hollow_app_lock_secret': '1234',
      'hollow_app_lock_launch_secret': '1234',
    }.entries) {
      _items[e.key] = (value: e.value, accessibility: 'unlocked');
    }

    final appLock = AppLockService();
    expect(await appLock.readLaunchSecret(), '1234');
    expect(await appLock.getLockType(), 'pin');
    expect(await appLock.isBiometricEnabled(), isTrue);
    expect(_items.values.map((i) => i.accessibility),
        everyElement('unlocked_this_device'));

    await appLock.storeLaunchSecret('246810');
    expect(await appLock.readLaunchSecret(), '246810');
  });
}

/// A push banner's avatar costs a decode only when it can be shown: a name read
/// (a channel wake's sender) and a banner App Lock hides ask Rust for no image.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/api/identity.dart';
import 'package:hollow/src/rust/api/network.dart';
import 'package:hollow/src/rust/frb_generated.dart';

class _Api implements RustLibApi {
  bool locked = false;
  final asks = <bool>[];

  @override
  Future<PushProfile?> crateApiNetworkGetPushProfile(
      {required String peerId, required bool withAvatar}) async {
    asks.add(withAvatar);
    return PushProfile(
        displayName: 'Ann',
        avatarBytes: withAvatar ? Uint8List.fromList([1, 2, 3]) : null);
  }

  @override
  Future<ProtectionStatus> crateApiIdentityGetIdentityProtectionStatus() async =>
      ProtectionStatus(
          isEncrypted: true,
          hasPassword: locked,
          hasOsKeychain: false,
          osKeychainAvailable: false);

  @override
  Future<String> crateApiNetworkIdentityFor({required String peerId}) async =>
      peerId;

  // No identity: the push log stays off.
  @override
  Future<bool> crateApiStorageHasIdentity() async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.asks.clear();
    api.locked = false;
  });

  test('an open DM banner asks for the avatar', () async {
    final (name, avatar, _) = await resolveDmPushProfileForTest('dev1');
    expect(name, 'Ann');
    expect(avatar, isNotNull);
    expect(api.asks, [true]);
  });

  test('a banner App Lock hides asks for no avatar at all', () async {
    api.locked = true;
    final (_, avatar, _) = await resolveDmPushProfileForTest('dev1');
    expect(avatar, isNull);
    expect(api.asks, [false]);
  });

  test('a channel wake reads the sender\'s name without its avatar', () async {
    expect(await channelWakeNameForTest('dev2'), 'Ann');
    expect(api.asks, [false]);
  });
}

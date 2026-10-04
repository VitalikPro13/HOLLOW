import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_frame_cryptor.dart';

class _LogApi implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _key(int fill) => Uint8List.fromList(List.filled(32, fill));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _LogApi()));

  test('a frame that fails to decrypt is never ratcheted (C-MEDIA-02)', () async {
    final native = FakeFrameCryptorFactory();
    await FrameCryptorService(factory: native).init();
    // Each ratchet step is two PBKDF2 runs of 100k iterations per failed frame,
    // and Hollow changes keys by epoch index only.
    expect(native.options!.ratchetWindowSize, 0);
  });

  test('a cryptor made after a rotation starts on the current slot (C-MEDIA-06)',
      () async {
    final native = FakeFrameCryptorFactory();
    final sframe = FrameCryptorService(factory: native);
    await sframe.init();
    await sframe.rotateKey(5, _key(5));
    native.calls.clear();

    await sframe.enableForSender('peer', FakeRtpSender(), kind: 'video');
    await sframe.enableForReceiver('peer', FakeRtpReceiver(), kind: 'video');

    for (final cryptor in ['tx0', 'rx1']) {
      final mine = native.calls.where((c) => c.startsWith('$cryptor.')).toList();
      expect(mine.first, '$cryptor.setKeyIndex:5',
          reason: 'slot 0 can hold an older epoch\'s key: $mine');
      expect(mine.indexOf('$cryptor.setEnabled:true'), greaterThan(0));
    }
  });

  test('an earlier epoch\'s key stops decrypting once the grace has passed '
      '(C-MEDIA-01)', () async {
    final native = FakeFrameCryptorFactory();
    final sframe = FrameCryptorService(
        factory: native, staleKeyGrace: const Duration(milliseconds: 40));
    await sframe.init();
    await sframe.rotateKey(3, _key(3));
    await sframe.rotateKey(4, _key(4));
    // A heal re-applies the current key: nothing goes stale.
    await sframe.rotateKey(4, _key(4));
    expect(native.keys.slots[3], _key(3), reason: 'in-flight frames still decrypt');

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(native.keys.slots[3], isNot(_key(3)),
        reason: 'a device the rotation removed still holds this key');
    expect(native.keys.slots[4], _key(4));
    expect(sframe.currentKeyIndex, 4);
  });

  test('a slot the epochs came back to is not overwritten', () async {
    final native = FakeFrameCryptorFactory();
    final sframe = FrameCryptorService(
        factory: native, staleKeyGrace: const Duration(milliseconds: 40));
    await sframe.init();
    await sframe.rotateKey(3, _key(3));
    await sframe.rotateKey(4, _key(4));
    await sframe.rotateKey(3, _key(9));

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(native.keys.slots[3], _key(9));
    expect(native.keys.slots[4], isNot(_key(4)));
  });
}

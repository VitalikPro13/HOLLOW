import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// The native side of SFrame, recording every call in order.
class FakeFrameCryptorFactory implements FrameCryptorFactory {
  final calls = <String>[];
  final keys = FakeKeyProvider();
  KeyProviderOptions? options;
  int _made = 0;

  @override
  Future<KeyProvider> createDefaultKeyProvider(KeyProviderOptions options) async {
    this.options = options;
    keys.calls = calls;
    return keys;
  }

  @override
  Future<FrameCryptor> createFrameCryptorForRtpSender({
    required String participantId,
    required RTCRtpSender sender,
    required Algorithm algorithm,
    required KeyProvider keyProvider,
  }) async =>
      FakeFrameCryptor('tx${_made++}', participantId, calls);

  @override
  Future<FrameCryptor> createFrameCryptorForRtpReceiver({
    required String participantId,
    required RTCRtpReceiver receiver,
    required Algorithm algorithm,
    required KeyProvider keyProvider,
  }) async =>
      FakeFrameCryptor('rx${_made++}', participantId, calls);
}

class FakeKeyProvider implements KeyProvider {
  List<String> calls = [];
  final slots = <int, Uint8List>{};

  @override
  String get id => 'keys';

  @override
  Future<void> setSharedKey({required Uint8List key, int index = 0}) async {
    slots[index] = Uint8List.fromList(key);
    calls.add('setSharedKey:$index');
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeFrameCryptor extends FrameCryptor {
  FakeFrameCryptor(this.name, this._participantId, this.calls);
  final String name;
  final String _participantId;
  final List<String> calls;

  @override
  String get participantId => _participantId;

  @override
  Future<bool> setEnabled(bool enabled) async {
    calls.add('$name.setEnabled:$enabled');
    return true;
  }

  @override
  Future<bool> get enabled async => true;

  @override
  Future<bool> setKeyIndex(int index) async {
    calls.add('$name.setKeyIndex:$index');
    return true;
  }

  @override
  Future<int> get keyIndex async => 0;

  @override
  Future<void> updateCodec(String codec) async {}

  @override
  Future<void> dispose() async => calls.add('$name.dispose');
}

class FakeRtpSender extends Fake implements RTCRtpSender {}

class FakeRtpReceiver extends Fake implements RTCRtpReceiver {}

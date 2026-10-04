import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_frame_cryptor.dart';

class _LogApi implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The body of the method whose declaration starts with [signature].
String _body(String src, String signature) {
  final at = src.indexOf(signature);
  expect(at, greaterThanOrEqualTo(0), reason: 'no $signature');
  final open = src.indexOf('{', src.indexOf(')', at));
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) return src.substring(open, i + 1);
  }
  fail('unbalanced $signature');
}

/// C-MEDIA-03: the forwarder ends DTLS, so a share leaves for it, and a forwarder's
/// copy is rendered, only with an SFrame layer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _LogApi()));

  test('a share rides a forwarder only once its cryptor holds a key', () async {
    expect(VoiceChannelNotifier.forwarderMayCarry(null), isFalse);
    final sframe = FrameCryptorService(factory: FakeFrameCryptorFactory());
    await sframe.init();
    expect(VoiceChannelNotifier.forwarderMayCarry(sframe), isFalse,
        reason: 'a keyless share would reach the forwarder in clear');
    await sframe.rotateKey(1, Uint8List(32));
    expect(VoiceChannelNotifier.forwarderMayCarry(sframe), isTrue);
  });

  test('every way onto a forwarder asks first', () {
    final src = File('lib/src/core/providers/voice_channel_provider.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    for (final signature in [
      // Sharer: routing a viewer, promoting, and the ingest leg itself.
      'String? _pickForwarderFor(',
      'String? _pickSpreadTargetFor(',
      'Future<bool> _maybeRebalanceOntoCandidate(',
      'Future<void> _ensureIngestLeg(',
      // Viewer: the route it asks for, the assignment and the attach.
      'Future<String> _routeHintTo(',
      'Future<void> _handleScreenAssign(',
      'Future<void> _handleFwdEgressOffer(',
    ]) {
      expect(_body(src, signature), contains('forwarderMayCarry('),
          reason: '$signature routes media past the SFrame gate');
    }
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

class _LogApi implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _LogApi()));
  const channel = MethodChannel('FlutterWebRTC.Method');

  test('trackless camera capture stays off, releases the stream and permits retry', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getUserMedia') {
        return {'streamId': 'empty-camera', 'audioTracks': [], 'videoTracks': []};
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final service = VoiceChannelService(localPeerId: 'local', iceServers: {});
    expect(await service.startCamera(), isNull);
    expect(service.isCameraOn, isFalse);
    expect(calls, contains('streamDispose'));
    expect(await service.startCamera(), isNull);
    expect(calls.where((method) => method == 'getUserMedia').length, 2);
  });
}

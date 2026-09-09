import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  const events = MethodChannel('FlutterWebRTC.Event');
  final calls = <MethodCall>[];
  bool missingDevice = false;

  setUp(() {
    calls.clear();
    missingDevice = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'selectAudioInput' && missingDevice) {
        throw PlatformException(code: 'AudioDeviceUnavailable', message: 'Missing microphone');
      }
      if (call.method == 'getUserMedia') {
        return {'streamId': 'capture', 'audioTracks': [], 'videoTracks': []};
      }
      return null;
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  test('Linux applies the Pulse source before opening capture', () async {
    await navigator.mediaDevices.getUserMedia({
      'audio': {'optional': [{'sourceId': 'alsa_input.test-microphone'}]},
      'video': false,
    });
    final audioCalls = calls.where((call) =>
        call.method == 'selectAudioInput' || call.method == 'getUserMedia').toList();
    expect(audioCalls.map((call) => call.method), ['selectAudioInput', 'getUserMedia']);
    expect(audioCalls.first.arguments, {'deviceId': 'alsa_input.test-microphone'});
  }, skip: !Platform.isLinux);

  test('a missing Linux microphone does not silently capture a different one', () async {
    missingDevice = true;
    await expectLater(navigator.mediaDevices.getUserMedia({'audio': true, 'video': false}),
        throwsA(contains('Missing microphone')));
    expect(calls.any((call) => call.method == 'getUserMedia'), isFalse);
  }, skip: !Platform.isLinux);

  test('camera-only capture does not select a microphone', () async {
    await navigator.mediaDevices.getUserMedia({'audio': false, 'video': true});
    expect(calls.any((call) => call.method == 'selectAudioInput'), isFalse);
  }, skip: !Platform.isLinux);
}

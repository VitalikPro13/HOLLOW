import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/services/voice_message_recorder.dart';
import 'package:hollow/src/core/services/voice_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_mic.dart';

/// Two edges of the overlay mic handover: a DM call that ended while its
/// capture waited for the mic, and a voice note, which needs the mic as much
/// as a call does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => RustLib.initMock(api: _Api()));

  const webrtc = MethodChannel('FlutterWebRTC.Method');
  const record = MethodChannel('com.llfbandit.record/messages');
  late List<String> events;
  late FakeMic mic;
  late OverlayMic listen;
  var micPermission = true;

  setUp(() {
    events = [];
    mic = FakeMic(events);
    listen = overlayMicOn(mic);
    debugOverlayMic = listen;
    micPermission = true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(webrtc, (call) async {
      if (call.method == 'getUserMedia') {
        events.add('call-getUserMedia');
        return {'streamId': 'mic', 'audioTracks': [], 'videoTracks': []};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(record, (call) async {
      if (call.method == 'hasPermission') {
        events.add('voice-note-permission');
        return micPermission;
      }
      return null;
    });
  });
  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(webrtc, null);
    messenger.setMockMethodCallHandler(record, null);
  });

  Future<void> resumeWindow() =>
      Future<void>.delayed(const Duration(milliseconds: 80));

  test('a DM call that ended while its capture waited hands the mic back',
      () async {
    await listen.turnOn();
    final svc = VoiceService(localPeerId: 'me', iceServers: const {})
      ..isCallLive = () => false;

    await svc.createOffer('peer', 'call').catchError((_) => '');
    await resumeWindow();

    expect(listen.holds, isEmpty,
        reason: 'nobody is left to release the hold of a call already gone');
    expect(listen.status.value.listening, isTrue);
  });

  test('a live DM call keeps the mic', () async {
    await listen.turnOn();
    final svc = VoiceService(localPeerId: 'me', iceServers: const {})
      ..isCallLive = () => true;

    await svc.createOffer('peer', 'call').catchError((_) => '');
    await resumeWindow();

    expect(listen.holds, contains(OverlayMicHold.dmCall));
    expect(listen.status.value.listening, isFalse);
  });

  test('a voice note stops listening before it opens the mic', () async {
    await listen.turnOn();
    micPermission = false;
    final recorder = VoiceMessageRecorder();

    await expectLater(recorder.start(),
        throwsA(isA<RecorderPermissionException>()));

    expect(events, containsAllInOrder(['mic-released', 'voice-note-permission']),
        reason: 'the note reached for the mic while listening still held it');
    await resumeWindow();
    expect(listen.status.value.listening, isTrue,
        reason: 'a note that never started hands the mic straight back');
    expect(listen.holds, isEmpty);
  });

  test('a voice note hands the mic back when it ends', () async {
    await listen.turnOn();
    await listen.yieldToCall(OverlayMicHold.voiceMessage);
    final recorder = VoiceMessageRecorder();

    await recorder.cancel();
    await resumeWindow();

    expect(listen.holds, isEmpty);
    expect(listen.status.value.listening, isTrue);
  });
}

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}

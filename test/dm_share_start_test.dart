import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack, RTCVideoRenderer;
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/services/desktop_capture_support.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// HOL-SEC-195, the DM call twin: a call that ended while the capture picker
/// was up got its capture started anyway, running with no call to end it.
void main() {
  final api = _Api();
  late Completer<MediaStream> picker;
  late int pickerOpens;
  late int previews;
  setUpAll(() {
    RustLib.initMock(api: api);
    SoundService.enabled = false;
  });
  setUp(() {
    api.signals.clear();
    picker = Completer<MediaStream>();
    pickerOpens = 0;
    ShareCapture.debugOpen = () {
      pickerOpens++;
      return picker.future;
    };
    previews = 0;
    ShareCapture.debugRenderer = () {
      previews++;
      return _Preview();
    };
  });
  tearDown(() {
    ShareCapture.debugOpen = null;
    ShareCapture.debugRenderer = null;
  });

  ({ProviderContainer c, CallNotifier call}) inCall() {
    final c = ProviderContainer(
      overrides: [
        callProvider.overrideWith(
          () => _InCall(
            const CallState(
              status: CallStatus.active,
              peerId: 'alice',
              callId: 'c1',
              direction: CallDirection.outgoing,
            ),
          ),
        ),
        deviceLinkProvider.overrideWith(_Links.new),
        webRtcProvider.overrideWith(_NoDataChannels.new),
      ],
    );
    addTearDown(c.dispose);
    return (c: c, call: c.read(callProvider.notifier));
  }

  Future<void> share(CallNotifier call) => call.startScreenShare(
    sourceId: 'screen:0',
    width: 1920,
    height: 1080,
    fps: 30,
  );

  test(
    'a call that ends during the picker leaves no capture running',
    () async {
      final r = inCall();
      final capture = _Capture();
      final starting = share(r.call);
      await pumpEventQueue();
      await r.call.handleCallSignal('alice', 'reject', 'c1');
      await pumpEventQueue(times: 50);
      expect(r.c.read(callProvider).status, CallStatus.idle);
      picker.complete(capture);
      await starting;
      await pumpEventQueue();

      expect(capture.disposes, 1, reason: 'the capture outlived its call');
      expect(previews, 0, reason: 'a preview was opened for a call that ended');
      expect(r.c.read(callProvider).isScreenSharing, isFalse);
      expect(r.call.localScreenShareRenderer, isNull);
      expect(
        api.signals.where((s) => s.contains('"enabled":true')),
        isEmpty,
        reason: 'a share was announced for a call that had ended',
      );
    },
  );

  test(
    'a call that ends while the preview opens leaves no capture running',
    () async {
      final r = inCall();
      final capture = _Capture();
      final opening = Completer<void>();
      final preview = _Preview(opening);
      ShareCapture.debugRenderer = () => preview;
      final starting = share(r.call);
      picker.complete(capture);
      await pumpEventQueue();
      await r.call.handleCallSignal('alice', 'reject', 'c1');
      await pumpEventQueue(times: 50);
      opening.complete();
      await starting;
      await pumpEventQueue();

      expect(capture.disposes, 1);
      expect(preview.disposes, 1);
      expect(r.c.read(callProvider).isScreenSharing, isFalse);
      expect(api.signals.where((s) => s.contains('"enabled":true')), isEmpty);
    },
  );

  test('a stop during the picker cancels the share', () async {
    final r = inCall();
    final capture = _Capture();
    final starting = share(r.call);
    await pumpEventQueue();
    await r.call.stopScreenShare();
    picker.complete(capture);
    await starting;

    expect(capture.disposes, 1);
    expect(r.c.read(callProvider).isScreenSharing, isFalse);
    expect(api.signals.where((s) => s.contains('"enabled":true')), isEmpty);
  });

  test('a second start while the picker is up is refused', () async {
    final r = inCall();
    final first = share(r.call);
    await pumpEventQueue();
    await share(r.call);
    expect(pickerOpens, 1, reason: 'two pickers race for one share');
    picker.complete(_Capture());
    await first;
    expect(r.c.read(callProvider).isScreenSharing, isTrue);
    await r.call.stopScreenShare();
  });
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);
  @override
  CallState build() => initial;
}

class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() => const DeviceLinkState(links: {});
}

class _NoDataChannels extends WebRtcNotifier {
  @override
  WebRtcService get service => throw StateError('no data channels here');
}

class _Api implements RustLibApi {
  final signals = <String>[];

  @override
  Future<void> crateApiNetworkCallSendSignal({
    required String peerId,
    required String signalType,
    required String payload,
  }) async {
    if (signalType == 'screen_state') signals.add(payload);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
      ? Future<void>.value()
      : super.noSuchMethod(invocation);
}

class _Preview extends RTCVideoRenderer {
  _Preview([this.gate]);
  final Completer<void>? gate;
  int disposes = 0;

  @override
  Future<void> initialize() async => gate?.future;

  @override
  Future<void> dispose() async {
    disposes++;
    await super.dispose();
  }

  @override
  set srcObject(MediaStream? stream) {}
}

class _Capture extends MediaStream {
  _Capture() : super('capture', 'local');
  int disposes = 0;

  @override
  Future<void> dispose() async => disposes++;

  @override
  bool? get active => true;

  @override
  List<MediaStreamTrack> getTracks() => const [];

  @override
  List<MediaStreamTrack> getAudioTracks() => const [];

  @override
  List<MediaStreamTrack> getVideoTracks() => const [];

  @override
  Future<void> addTrack(MediaStreamTrack track, {bool addToNative = true}) =>
      throw UnimplementedError();

  @override
  Future<void> removeTrack(
    MediaStreamTrack track, {
    bool removeFromNative = true,
  }) => throw UnimplementedError();

  @override
  // ignore: deprecated_member_use
  Future<void> getMediaTracks() => throw UnimplementedError();
}

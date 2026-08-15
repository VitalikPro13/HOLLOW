import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/audio_route.dart';

/// The rule these tests exist for: **a connected headset always beats the
/// built-in loudspeaker.** Hollow defaults voice channels and video calls to
/// "speaker on", and forcing the loudspeaker over an attached headset leaves
/// the user in silence — the field bug this file guards against.
///
/// Host tests aren't Android/iOS, so `debugSupportedOverride` opens the gate
/// and the non-Android branch (iOS shapes) is what gets exercised.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('FlutterWebRTC.Method');
  late List<MethodCall> calls;
  late List<Map<String, Object?>> sources;

  Map<String, Object?> input(String uid, String portType, String label) => {
        'deviceId': uid,
        'groupId': portType,
        'label': label,
        'kind': 'audioinput',
      };

  Map<String, Object?> output(String uid, String portType, String label) => {
        'deviceId': uid,
        'groupId': portType,
        'label': label,
        'kind': 'audiooutput',
      };

  bool invoked(String method) => calls.any((c) => c.method == method);

  MethodCall? callOf(String method) {
    for (final c in calls) {
      if (c.method == method) return c;
    }
    return null;
  }

  setUp(() {
    AudioRoutes.debugSupportedOverride = true;
    calls = [];
    sources = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getSources') return {'sources': sources};
      if (call.method == 'hollowSelectedAudioOutput') return null;
      return null;
    });
  });

  tearDown(() {
    AudioRoutes.debugSupportedOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('route classification', () {
    test('reads both platform vocabularies', () {
      // Android — AudioDeviceKind type names.
      expect(AudioRoutes.kindFromToken('speaker'), AudioRouteKind.speaker);
      expect(AudioRoutes.kindFromToken('earpiece'), AudioRouteKind.earpiece);
      expect(AudioRoutes.kindFromToken('wired-headset'), AudioRouteKind.wired);
      expect(
          AudioRoutes.kindFromToken('bluetooth'), AudioRouteKind.bluetooth);
      // iOS — AVAudioSessionPort raw values.
      expect(AudioRoutes.kindFromToken('Speaker'), AudioRouteKind.speaker);
      expect(AudioRoutes.kindFromToken('Receiver'), AudioRouteKind.earpiece);
      expect(AudioRoutes.kindFromToken('MicrophoneBuiltIn'),
          AudioRouteKind.earpiece);
      expect(AudioRoutes.kindFromToken('MicrophoneWired'),
          AudioRouteKind.wired);
      expect(AudioRoutes.kindFromToken('Headphones'), AudioRouteKind.wired);
      expect(AudioRoutes.kindFromToken('BluetoothHFP'),
          AudioRouteKind.bluetooth);
      expect(AudioRoutes.kindFromToken('USBAudio'), AudioRouteKind.usb);
      expect(AudioRoutes.kindFromToken(null), isNull);
      expect(AudioRoutes.kindFromToken('NotAPort'), isNull);
    });

    test('only attached devices count as external', () {
      expect(AudioRouteKind.speaker.isExternal, isFalse);
      expect(AudioRouteKind.earpiece.isExternal, isFalse);
      expect(AudioRouteKind.wired.isExternal, isTrue);
      expect(AudioRouteKind.bluetooth.isExternal, isTrue);
      expect(AudioRouteKind.usb.isExternal, isTrue);
    });
  });

  group('enumeration', () {
    test('the loudspeaker is always offered, even when it is not live', () async {
      // getSources reports only the LIVE output; the loudspeaker stays
      // reachable through a port override regardless.
      sources = [
        input('BuiltInMicUID', 'MicrophoneBuiltIn', 'iPhone Microphone'),
        output('ReceiverUID', 'Receiver', 'Receiver'),
      ];
      final routes = await AudioRoutes.list();
      expect(routes.map((r) => r.kind),
          containsAll([AudioRouteKind.speaker, AudioRouteKind.earpiece]));
    });

    test('a headset hidden behind a speaker override is still found',
        () async {
      // While overrideOutputAudioPort(.speaker) is in effect the headset
      // vanishes from currentRoute.outputs — its INPUT port is the only
      // evidence left that it is plugged in.
      sources = [
        input('BuiltInMicUID', 'MicrophoneBuiltIn', 'iPhone Microphone'),
        input('WiredMicUID', 'MicrophoneWired', 'Headset Microphone'),
        output('Speaker', 'Speaker', 'Speaker'),
      ];
      final routes = await AudioRoutes.list();
      final wired =
          routes.firstWhere((r) => r.kind == AudioRouteKind.wired);
      expect(wired.inputUid, 'WiredMicUID',
          reason: 'iOS picks an output by pinning its INPUT port');
      expect(await AudioRoutes.hasExternalRoute(), isTrue);
    });

    test('routes are listed in a stable order and deduped by kind', () async {
      sources = [
        input('WiredMicUID', 'MicrophoneWired', 'Headset Microphone'),
        input('BuiltInMicUID', 'MicrophoneBuiltIn', 'iPhone Microphone'),
        output('HeadphonesUID', 'Headphones', 'Headphones'),
      ];
      final routes = await AudioRoutes.list();
      expect(routes.map((r) => r.kind).toList(),
          [AudioRouteKind.speaker, AudioRouteKind.earpiece, AudioRouteKind.wired]);
    });

    test('attached devices keep their platform name, built-ins are canonical',
        () async {
      sources = [
        input('BuiltInMicUID', 'MicrophoneBuiltIn', 'iPhone Microphone'),
        input('BtUID', 'BluetoothHFP', "Vitalik's AirPods"),
      ];
      final routes = await AudioRoutes.list();
      expect(routes.firstWhere((r) => r.kind == AudioRouteKind.earpiece).label,
          'Earpiece');
      expect(
          routes.firstWhere((r) => r.kind == AudioRouteKind.bluetooth).label,
          "Vitalik's AirPods");
    });
  });

  group('preferLoudRoute — the headset must win', () {
    test('with a headset attached it does NOT force the loudspeaker',
        () async {
      sources = [
        input('BuiltInMicUID', 'MicrophoneBuiltIn', 'iPhone Microphone'),
        input('WiredMicUID', 'MicrophoneWired', 'Headset Microphone'),
      ];
      await AudioRoutes.preferLoudRoute(true);
      expect(invoked('enableSpeakerphoneButPreferBluetooth'), isTrue);
      expect(invoked('enableSpeakerphone'), isFalse,
          reason: 'a hard speaker override outranks headphones and silences '
              'the user');
    });

    test('with only built-in routes it forces the loudspeaker', () async {
      sources = [
        input('BuiltInMicUID', 'MicrophoneBuiltIn', 'iPhone Microphone'),
        output('ReceiverUID', 'Receiver', 'Receiver'),
      ];
      await AudioRoutes.preferLoudRoute(true);
      expect(callOf('enableSpeakerphone')?.arguments['enable'], isTrue);
      expect(invoked('enableSpeakerphoneButPreferBluetooth'), isFalse);
    });

    test('speaker off never consults the device list', () async {
      await AudioRoutes.preferLoudRoute(false);
      expect(callOf('enableSpeakerphone')?.arguments['enable'], isFalse);
      expect(invoked('getSources'), isFalse);
    });
  });

  group('select', () {
    test('picking a headset clears the override, then pins its input',
        () async {
      await AudioRoutes.select(const AudioRoute(
        id: 'WiredMicUID',
        label: 'Wired headset',
        kind: AudioRouteKind.wired,
        inputUid: 'WiredMicUID',
      ));
      final methods = calls.map((c) => c.method).toList();
      expect(methods, ['enableSpeakerphone', 'selectAudioInput'],
          reason: 'the loudspeaker override outranks every attached device, '
              'so it has to go first');
      expect(callOf('enableSpeakerphone')?.arguments['enable'], isFalse);
      expect(
          callOf('selectAudioInput')?.arguments['deviceId'], 'WiredMicUID');
    });

    test('picking the loudspeaker forces it', () async {
      await AudioRoutes.select(const AudioRoute(
          id: 'Speaker', label: 'Speaker', kind: AudioRouteKind.speaker));
      expect(callOf('enableSpeakerphone')?.arguments['enable'], isTrue);
      expect(invoked('selectAudioInput'), isFalse);
    });
  });

  group('unsupported platforms', () {
    test('desktop enumerates nothing and touches no channel', () async {
      AudioRoutes.debugSupportedOverride = false;
      expect(await AudioRoutes.list(), isEmpty);
      expect(await AudioRoutes.current(), isNull);
      await AudioRoutes.preferLoudRoute(true);
      await AudioRoutes.select(const AudioRoute(
          id: 'Speaker', label: 'Speaker', kind: AudioRouteKind.speaker));
      expect(calls, isEmpty);
    });
  });
}

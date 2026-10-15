import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/mic_level_capture.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';

import 'helpers/fake_mic.dart';

/// "Listen to my mic now" (stream overlay plan 7a): a call never opens the mic
/// while listening holds it, listening comes back only when the call has fully
/// let go and the button is still on, and nothing about it survives a restart.
void main() {
  late List<String> events;
  late FakeMic mic;
  late OverlayMic listen;

  setUp(() {
    events = [];
    mic = FakeMic(events);
    listen = overlayMicOn(mic);
  });

  Future<void> settle() => pumpEventQueue(times: 50);

  test('starts off, as after every app start', () {
    final fresh = OverlayMic();
    expect(fresh.status.value.on, isFalse);
    expect(fresh.status.value.listening, isFalse);
    expect(fresh.holds, isEmpty);
  });

  test('the call capture starts only after the stop has released the mic',
      () async {
    await listen.turnOn();
    expect(listen.status.value.listening, isTrue);

    await listen.yieldToCall(OverlayMicHold.voiceChannel);
    events.add('call-getUserMedia');

    expect(events, ['mic-opening', 'mic-open', 'mic-released',
        'call-getUserMedia']);
    expect(listen.status.value.listening, isFalse);
    expect(listen.status.value.paused, isTrue);
  });

  test('a yield landing mid-start waits for that start, then stops it',
      () async {
    mic.openGate = Completer<void>();
    final starting = listen.turnOn();
    await settle();
    expect(events, ['mic-opening']);

    final yielded = listen
        .yieldToCall(OverlayMicHold.dmCall)
        .then((_) => events.add('call-getUserMedia'));
    await settle();
    expect(events, isNot(contains('call-getUserMedia')),
        reason: 'the mic is still opening, so the call must wait');

    mic.openGate!.complete();
    await starting;
    await yielded;
    expect(events, ['mic-opening', 'mic-open', 'mic-released',
        'call-getUserMedia']);
    expect(mic.isOpen, isFalse);
  });

  test('turning on during a call waits for the call to end', () async {
    await listen.yieldToCall(OverlayMicHold.dmCall);
    await listen.turnOn();
    expect(mic.opens, 0);
    expect(listen.status.value.paused, isTrue);

    listen.release(OverlayMicHold.dmCall);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(listen.status.value.listening, isTrue);
  });

  test('listening resumes after the call let go, only if still on', () async {
    await listen.turnOn();
    await listen.yieldToCall(OverlayMicHold.voiceChannel);
    listen.release(OverlayMicHold.voiceChannel);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(listen.status.value.listening, isTrue);
    expect(mic.opens, 2);

    await listen.yieldToCall(OverlayMicHold.voiceChannel);
    await listen.turnOff();
    listen.release(OverlayMicHold.voiceChannel);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(listen.status.value.listening, isFalse);
    expect(mic.opens, 2, reason: 'turned off during the call: no reopen');
  });

  test('nothing resumes before the call has released its hold', () async {
    await listen.turnOn();
    await listen.yieldToCall(OverlayMicHold.voiceChannel);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(mic.opens, 1, reason: 'no resume while the call holds the mic');
  });

  test('switching rooms inside the resume delay never reopens the mic',
      () async {
    final slow = overlayMicOn(mic,
        resumeDelay: const Duration(milliseconds: 100));
    await slow.turnOn();
    await slow.yieldToCall(OverlayMicHold.voiceChannel);
    slow.release(OverlayMicHold.voiceChannel);
    await slow.yieldToCall(OverlayMicHold.voiceChannel);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(mic.opens, 1);
  });

  test('two holds: listening resumes only once both have let go', () async {
    await listen.turnOn();
    await listen.yieldToCall(OverlayMicHold.voiceChannel);
    await listen.yieldToCall(OverlayMicHold.dmCall);
    listen.release(OverlayMicHold.voiceChannel);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(listen.status.value.listening, isFalse);
    listen.release(OverlayMicHold.dmCall);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(listen.status.value.listening, isTrue);
  });

  test('the microphone test pauses listening and resumes it after', () async {
    await listen.turnOn();
    await listen.yieldToCall(OverlayMicHold.micTest);
    expect(events.last, 'mic-released');
    expect(listen.status.value.paused, isTrue);

    listen.release(OverlayMicHold.micTest);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(listen.status.value.listening, isTrue);
  });

  test('a release nobody held starts nothing', () async {
    await listen.turnOn();
    await listen.turnOff();
    listen.release(OverlayMicHold.dmCall);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(mic.opens, 1);
  });

  test('a microphone that will not open leaves listening off', () async {
    mic.openError = StateError('no device');
    await expectLater(listen.turnOn(), throwsStateError);
    expect(listen.status.value.on, isFalse);
    expect(listen.status.value.listening, isFalse);
  });

  test('speaking follows the threshold and holds through short gaps',
      () async {
    var now = DateTime(2026, 10, 15);
    final timed = overlayMicOn(mic, now: () => now);
    final levels = <double>[];
    timed.onLevelDb = levels.add;
    timed.hold = const Duration(milliseconds: 250);
    await timed.turnOn();

    mic.feed(3000); // about -21 dBFS
    await settle();
    expect(timed.speaking.value, isTrue);

    now = now.add(const Duration(milliseconds: 100));
    mic.feed(20); // about -64 dBFS
    await settle();
    expect(timed.speaking.value, isTrue, reason: 'inside the hold');

    now = now.add(const Duration(milliseconds: 200));
    mic.feed(20);
    await settle();
    expect(timed.speaking.value, isFalse);

    timed.thresholdDb = -70;
    mic.feed(20);
    await settle();
    expect(timed.speaking.value, isTrue, reason: 'more sensitive');
    expect(levels.first, closeTo(-20.8, 0.1));
  });

  group('MicLevelCapture.rmsDbFromPcm16', () {
    Uint8List square(int amplitude, int samples) {
      final data = ByteData(samples * 2);
      for (var i = 0; i < samples; i++) {
        data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
      }
      return data.buffer.asUint8List();
    }

    test('full scale reads 0 dBFS, half scale -6', () {
      expect(MicLevelCapture.rmsDbFromPcm16(square(32767, 100)),
          closeTo(0.0, 0.01));
      expect(MicLevelCapture.rmsDbFromPcm16(square(16384, 100)),
          closeTo(-6.02, 0.01));
    });

    test('silence and empty chunks read the silence floor', () {
      expect(MicLevelCapture.rmsDbFromPcm16(Uint8List(0)),
          MicLevelCapture.silenceDb);
      expect(MicLevelCapture.rmsDbFromPcm16(Uint8List(64)),
          MicLevelCapture.silenceDb);
    });

    test('an odd offset into a shared buffer still reads', () {
      final backing = Uint8List(201);
      backing.setRange(1, 201, square(16384, 100));
      final view = Uint8List.sublistView(backing, 1);
      expect(MicLevelCapture.rmsDbFromPcm16(view), closeTo(-6.02, 0.01));
    });
  });
}

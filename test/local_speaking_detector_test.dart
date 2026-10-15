import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/local_speaking_detector.dart';

/// Feeds the detector one scripted native reading per poll.
LocalSpeakingDetector _detector(List<Map<String, dynamic>> readings) {
  var i = 0;
  return LocalSpeakingDetector(
      read: () async => readings[i < readings.length ? i++ : readings.length - 1]);
}

Map<String, dynamic> _r(double db, [double vad = -1.0]) =>
    {'levelDb': db, 'vad': vad};

void main() {
  test('a live meter above the floor is speech, below it is not', () async {
    final d = _detector([_r(-70), _r(-30), _r(-31), _r(-60)]);
    expect(await d.poll(muted: false), isFalse); // first reading proves nothing
    expect(await d.poll(muted: false), isTrue);
    expect(d.levelDb, -30);
    expect(await d.poll(muted: false), isTrue);
    expect(await d.poll(muted: false), isFalse);
    expect(d.hasMeter, isTrue);
  });

  test('the denoiser VAD decides when it runs', () async {
    final d = _detector([_r(-50, 0.1), _r(-30, 0.2), _r(-29, 0.9)]);
    await d.poll(muted: false);
    expect(await d.poll(muted: false), isFalse);
    expect(await d.poll(muted: false), isTrue);
  });

  test('a frozen meter is not a voice: the capture stopped mid-word', () async {
    // The native peak-hold decays every 10 ms frame it processes, so a live
    // meter never repeats a reading across polls. An unchanged value means
    // nothing is being captured (alone in a room, the last peer just left),
    // and holding "talking" there kept the self ring lit for good.
    final d = _detector([_r(-30), _r(-28), _r(-28), _r(-28)]);
    await d.poll(muted: false);
    expect(await d.poll(muted: false), isTrue);
    expect(await d.poll(muted: false), isFalse);
    expect(d.levelDb, isNull);
    expect(await d.poll(muted: false), isFalse);
  });

  test('a stale reading left by an earlier session never lights at join',
      () async {
    final d = _detector([_r(-25), _r(-25), _r(-25)]);
    for (var i = 0; i < 3; i++) {
      expect(await d.poll(muted: false), isFalse);
    }
    expect(d.hasMeter, isFalse);
    expect(d.levelDb, isNull);
  });

  test('no meter at all (-100) holds the last state and reports no level',
      () async {
    final d = _detector([_r(-70), _r(-30), _r(-100), _r(-100)]);
    await d.poll(muted: false);
    expect(await d.poll(muted: false), isTrue);
    expect(await d.poll(muted: false), isTrue);
    expect(d.levelDb, isNull);
  });

  test('muted is silent whatever the meter says', () async {
    final d = _detector([_r(-70), _r(-20), _r(-19)]);
    await d.poll(muted: false);
    expect(await d.poll(muted: false), isTrue);
    expect(d.levelDb, -20);
    expect(await d.poll(muted: true), isFalse);
    expect(d.levelDb, isNull);
  });

  test('a failing read keeps the last state', () async {
    var n = 0;
    final d = LocalSpeakingDetector(read: () async {
      n++;
      if (n == 3) throw StateError('channel gone');
      return _r(n == 1 ? -70 : -30);
    });
    await d.poll(muted: false);
    expect(await d.poll(muted: false), isTrue);
    expect(await d.poll(muted: false), isTrue);
  });
}

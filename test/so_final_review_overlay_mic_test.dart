import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/mic_level_capture.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';

import 'helpers/fake_mic.dart';

/// so-final-review: every call path (DM accept, outgoing call, voice channel
/// join, voice note) awaits [OverlayMic.yieldToCall] before it opens the mic.
/// That wait must be bounded: a capture backend that never lets go (a wedged
/// native recorder) must not keep a call from ever opening its microphone.
void main() {
  test('a call is never held forever by a capture that does not let go',
      () async {
    final events = <String>[];
    final mic = FakeMic(events, closeDelay: const Duration(hours: 1));
    final listen = overlayMicOn(mic);
    await listen.turnOn();
    expect(mic.isOpen, isTrue, reason: 'precondition: listening');

    var yielded = false;
    unawaited(listen
        .yieldToCall(OverlayMicHold.voiceChannel)
        .then((_) => yielded = true));
    await Future<void>.delayed(const Duration(seconds: 6));
    expect(yielded, isTrue,
        reason: 'the call is still waiting for the overlay capture to let '
            'go of the mic, with no bound');
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('after a yield that gave up, listening reopens only once the late '
      'close has let go', () async {
    final events = <String>[];
    final mic = FakeMic(events, closeDelay: const Duration(milliseconds: 400));
    final listen = OverlayMic(
      newCapture: () => MicLevelCapture(backend: () => mic),
      resumeDelay: const Duration(milliseconds: 10),
      stopTimeout: const Duration(milliseconds: 50),
      log: (_) {},
    );
    await listen.turnOn();

    await listen.yieldToCall(OverlayMicHold.voiceChannel);
    expect(events.last, 'mic-open', reason: 'the yield gave up waiting');
    expect(listen.status.value.listening, isFalse);

    listen.release(OverlayMicHold.voiceChannel);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(events,
        ['mic-opening', 'mic-open', 'mic-released', 'mic-opening', 'mic-open']);
    expect(listen.status.value.listening, isTrue);
  });
}

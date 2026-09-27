import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';

import 'helpers/test_app.dart';

/// HOL-SEC-037 (M1). Call signals were matched by call id alone, so anyone who
/// learned the id could end, answer or re-point someone else's call, and an
/// `audio_state` with no call id at all applied to whatever call was live.
void main() {
  ProviderContainer inCallWith(String peer) {
    final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        callProvider.overrideWith(() => _InCall(CallState(
              status: CallStatus.active,
              peerId: peer,
              callId: 'c1',
              direction: CallDirection.outgoing,
            ))),
      ]),
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a signal from anyone but the call peer changes nothing', () async {
    final container = inCallWith('alice');
    final call = container.read(callProvider.notifier);

    await call.handleCallSignal(
        'mallory', 'audio_state', '{"call_id":"c1","muted":true}');
    expect(container.read(callProvider).remoteMuted, isFalse);

    await call.handleCallSignal('mallory', 'end', '{"call_id":"c1"}');
    expect(container.read(callProvider).status, CallStatus.active);
  });

  test('the call peer still reaches its call, but only by its id', () async {
    final container = inCallWith('alice');
    final call = container.read(callProvider.notifier);

    await call.handleCallSignal('alice', 'audio_state', '{"muted":true}');
    expect(container.read(callProvider).remoteMuted, isFalse,
        reason: 'an audio_state naming no call applies to none');

    await call.handleCallSignal(
        'alice', 'audio_state', '{"call_id":"c1","muted":true}');
    expect(container.read(callProvider).remoteMuted, isTrue);
  });
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);
  @override
  CallState build() => initial;
}

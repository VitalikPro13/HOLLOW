import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/realtime_session_flag.dart';

/// The bug this file exists for (field-caught 2026-08-27): the relay socket
/// backs off exponentially toward thirty seconds, a machine lost its network
/// for 25 seconds mid-call, and the socket did not try to reconnect until
/// ELEVEN SECONDS after the call had already been given up on. The user's
/// internet had been working for twenty of those seconds while they watched
/// "Reconnecting".
///
/// The flag is what tells the socket to stop backing off, so the edges have to
/// be exactly right: a missed acquire means the slow path during a call, and a
/// premature release means the same thing with a session still running.
void main() {
  late List<bool> pushed;

  // Sink FIRST, then reset: the flag is process-global static state, so a
  // reset with no sink installed reaches for the real Rust library, which a
  // widget test has never loaded.
  setUp(() {
    pushed = [];
    RealtimeSessionFlag.sink = pushed.add;
    RealtimeSessionFlag.reset();
    pushed.clear();
  });

  tearDown(() {
    RealtimeSessionFlag.reset();
    RealtimeSessionFlag.sink = null;
  });

  test('pushes only the EDGES, not every call', () {
    RealtimeSessionFlag.acquire('dm-call');
    RealtimeSessionFlag.acquire('dm-call');
    RealtimeSessionFlag.acquire('dm-call');
    expect(pushed, [true], reason: 'startCall and acceptCall both acquire on '
        'the same call; the socket needs telling once');
  });

  test('stays held while ANY session holds it', () {
    RealtimeSessionFlag.acquire('dm-call');
    RealtimeSessionFlag.acquire('voice-channel');
    RealtimeSessionFlag.release('dm-call');
    expect(RealtimeSessionFlag.isActive, isTrue);
    expect(pushed, [true],
        reason: 'leaving one session while another runs must NOT put the '
            'socket back on the slow path');
    RealtimeSessionFlag.release('voice-channel');
    expect(pushed, [true, false]);
  });

  test('releasing something that never started is harmless', () {
    RealtimeSessionFlag.release('dm-call');
    expect(pushed, isEmpty,
        reason: 'teardown paths run on failures too, before any acquire');
    expect(RealtimeSessionFlag.isActive, isFalse);
  });

  test('a full cycle leaves the socket back on the idle policy', () {
    RealtimeSessionFlag.acquire('dm-call');
    RealtimeSessionFlag.release('dm-call');
    expect(pushed, [true, false]);
    expect(RealtimeSessionFlag.holders, isEmpty);
  });

  test('reset clears everything and pushes false once', () {
    RealtimeSessionFlag.acquire('dm-call');
    RealtimeSessionFlag.acquire('voice-channel');
    RealtimeSessionFlag.reset();
    expect(pushed, [true, false]);
    expect(RealtimeSessionFlag.isActive, isFalse);
  });

  test('reset on an idle flag pushes nothing', () {
    RealtimeSessionFlag.reset();
    expect(pushed, isEmpty);
  });
}

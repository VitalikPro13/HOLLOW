// The desktop app lock's idle rule, kept pure so it can be tested without a
// clock or a widget tree.
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';

void main() {
  final lastInput = DateTime(2026, 9, 11, 12, 0);

  bool decide({
    int minutes = 5,
    Duration since = const Duration(minutes: 6),
    bool busy = false,
    bool locked = false,
  }) =>
      shouldAutoLock(
        lockAfterMinutes: minutes,
        lastInput: lastInput,
        now: lastInput.add(since),
        busy: busy,
        locked: locked,
      );

  test('off never locks, however long the wait', () {
    expect(decide(minutes: 0, since: const Duration(hours: 9)), isFalse);
  });

  test('locks once the span has passed, not before', () {
    expect(decide(since: const Duration(minutes: 4, seconds: 59)), isFalse);
    expect(decide(since: const Duration(minutes: 5)), isTrue);
    expect(decide(since: const Duration(minutes: 5, seconds: 1)), isTrue);
  });

  test('a call, a voice channel or a transfer holds the lock off', () {
    expect(decide(busy: true, since: const Duration(hours: 2)), isFalse);
  });

  test('already locked does not lock again', () {
    expect(decide(locked: true), isFalse);
  });

  test('every offered span is a real choice', () {
    expect(kLockAfterChoices.first, 0);
    for (final minutes in kLockAfterChoices.skip(1)) {
      expect(decide(minutes: minutes, since: Duration(minutes: minutes)),
          isTrue,
          reason: '$minutes must lock at its own span');
      expect(
          decide(
              minutes: minutes, since: Duration(minutes: minutes) - const Duration(seconds: 1)),
          isFalse,
          reason: '$minutes must not lock early');
    }
  });
}

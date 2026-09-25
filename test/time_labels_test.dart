import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/time_labels.dart';

void main() {
  final now = DateTime(2026, 9, 23, 18, 30); // a Wednesday

  test('today shows the 24 hour time', () {
    expect(conversationTimeLabel(DateTime(2026, 9, 23, 9, 5), now: now),
        '09:05');
  });

  test('yesterday, then the weekday within the week', () {
    expect(conversationTimeLabel(DateTime(2026, 9, 22, 23, 59), now: now),
        'Yesterday');
    expect(conversationTimeLabel(DateTime(2026, 9, 18), now: now), 'Fri');
  });

  test('older dates use the month name, and the year only when it differs',
      () {
    expect(conversationTimeLabel(DateTime(2026, 9, 16), now: now), 'Sep 16');
    expect(conversationTimeLabel(DateTime(2025, 12, 31), now: now),
        'Dec 31, 2025');
  });

  test('a clock slightly ahead never reads as the future', () {
    expect(conversationTimeLabel(DateTime(2026, 9, 24, 0, 1), now: now),
        '00:01');
  });

  test('an unset time is empty, never a 1970 date', () {
    expect(
        conversationTimeLabel(DateTime.fromMillisecondsSinceEpoch(0), now: now),
        '');
  });

  test('relative labels count minutes, hours, then days', () {
    expect(relativeTimeLabel(DateTime(2026, 9, 23, 18, 29, 30), now: now),
        'just now');
    expect(relativeTimeLabel(DateTime(2026, 9, 23, 18, 29), now: now),
        '1 minute ago');
    expect(relativeTimeLabel(DateTime(2026, 9, 23, 15, 10), now: now),
        '3 hours ago');
    expect(relativeTimeLabel(DateTime(2026, 9, 22, 12), now: now),
        'yesterday');
    expect(relativeTimeLabel(DateTime(2026, 9, 19, 12), now: now),
        '4 days ago');
    expect(relativeTimeLabel(DateTime(2026, 9, 1), now: now), 'on Sep 1');
  });

  test('a calendar date is a day in words, never a time of day', () {
    expect(calendarDateLabel(DateTime(2026, 9, 23, 18, 5), now: now), 'Sep 23');
    expect(calendarDateLabel(DateTime(2025, 12, 31), now: now),
        'Dec 31, 2025');
  });
}

/// Home's title, by the local clock: night until 6, morning until 12,
/// afternoon until 18, evening after.
String greetingFor(DateTime now) {
  final h = now.hour;
  if (h < 6) return 'Good night';
  if (h < 12) return 'Good morning';
  if (h < 18) return 'Good afternoon';
  return 'Good evening';
}

/// What Home calls someone who has not picked a name yet.
const kNamelessGreeting = 'Kind Stranger';

/// When [greetingFor] next changes its answer.
DateTime nextGreetingChange(DateTime now) {
  final next = ((now.hour ~/ 6) + 1) * 6;
  return DateTime(now.year, now.month, now.day, next);
}

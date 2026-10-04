/// True when [error] is Rust's answer to a duress code: the data is already
/// gone by the time the caller hears it. Matched on the exact word, never a
/// substring, because a mistyped password must never take this branch.
bool isDuressResult(Object error) {
  final message = error.toString().trim();
  return message == 'duress' ||
      message.endsWith('(duress)') ||
      message.endsWith(': duress');
}

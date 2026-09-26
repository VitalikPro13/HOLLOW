import 'dart:async';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException, PanicException;
import 'package:flutter/services.dart' show PlatformException;
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// An error whose message is already written for a person: [friendlyError]
/// shows it word for word. Throw it from a dialog's `onConfirm` when the
/// failure has a specific sentence ("That name is taken").
class FriendlyException implements Exception {
  final String message;
  const FriendlyException(this.message);

  @override
  String toString() => message;
}

/// The sentence a person sees when [error] fails their action: one plain line
/// with a next step, never the raw exception. The raw text goes to
/// `hollow_debug.log` instead.
///
/// [fallback] replaces the generic line for an error no rule recognises, for
/// a caller that can say what failed ("Couldn't leave the server. Try again.").
String friendlyError(Object error, {String? fallback}) {
  if (error is FriendlyException) return error.message;
  final raw = _rawMessage(error);
  _log(error, raw);
  final lower = raw.toLowerCase();
  for (final rule in _rules) {
    if (rule.matches(lower)) return rule.sentence;
  }
  // Only text Rust wrote can pass through: a Dart error's toString is always
  // a debug string ("Bad state: ...").
  final fromRust = error is String || error is AnyhowException;
  if (fromRust && _readsAsSentence(raw)) {
    final trimmed = raw.trim();
    return RegExp(r'[.!?]$').hasMatch(trimmed) ? trimmed : '$trimmed.';
  }
  return fallback ?? kGenericErrorSentence;
}

/// What a person sees when nothing more specific is known.
const kGenericErrorSentence = 'Something went wrong. Try again.';

String _rawMessage(Object error) {
  if (error is AnyhowException) return error.message;
  if (error is PanicException) return 'panic: ${error.message}';
  if (error is PlatformException) {
    return [error.code, error.message].whereType<String>().join(': ');
  }
  if (error is TimeoutException) return 'timed out';
  return error.toString();
}

/// Raw texts already logged: a failed row shows its sentence from `build`, and
/// every rebuild would log the same failure again.
final _logged = <String>{};

void _log(Object error, String raw) {
  if (!_logged.add(raw)) return;
  if (_logged.length > 256) _logged.remove(_logged.first);
  try {
    network_api
        .logFromDart(message: '[friendlyError] ${error.runtimeType}: $raw')
        .catchError((_) {});
  } catch (_) {
    // The bridge is not up (tests, or before the node starts).
  }
}

/// A message Rust already wrote for people passes through: capitalised, one
/// short line, and none of the marks of a debug string.
bool _readsAsSentence(String raw) {
  final text = raw.trim();
  if (text.length < 8 || text.length > 160) return false;
  if (!RegExp(r'^[A-Z]').hasMatch(text)) return false;
  const tells = [
    '::', '{', '}', '\n', '\\', '`', '0x', 'Exception', 'Error:', 'error:',
    'os error', 'HTTP', 'panic', 'errno', 'Instance of',
  ];
  return !tells.any(text.contains);
}

class _Rule {
  final List<String> needles;
  final String sentence;
  const _Rule(this.needles, this.sentence);

  bool matches(String lower) => needles.any(lower.contains);
}

// First match wins, so the specific shapes sit above the broad ones ("identity
// is locked" before "not found", "disk full" before "permission denied").
const _rules = <_Rule>[
  _Rule(
    ['identity is locked', 'identity locked', 'not unlocked',
        'provide a password', 'unlock_identity', 'wrapping key'],
    'Hollow is locked. Unlock it and try again.',
  ),
  _Rule(
    ['node is not running', 'node not running', 'node not started'],
    'Hollow is still starting up. Try again in a moment.',
  ),
  _Rule(
    ['no space left', 'disk full', 'not enough space', 'os error 28',
        'os error 112'],
    'Your disk is full. Free some space and try again.',
  ),
  _Rule(
    ['rate limit', 'rate-limit', 'too many requests', ' 429'],
    'That was asked for too often. Wait a minute and try again.',
  ),
  _Rule(
    ['timed out', 'timeout', 'deadline has elapsed', 'deadline exceeded'],
    'That took too long to answer. Try again in a moment.',
  ),
  _Rule(
    ['relay', 'not connected', 'connection refused', 'connection reset',
        'connection closed', 'network is unreachable', 'no route to host',
        'failed host lookup', 'socketexception', 'websocket', 'dns error',
        'unreachable'],
    "Hollow can't reach the relay right now. Check your connection and try "
        'again.',
  ),
  _Rule(
    ['access is denied', 'os error 5)', 'os error 13', 'read-only file system'],
    "Hollow isn't allowed to use that location. Pick another folder and try "
        'again.',
  ),
  _Rule(
    ['permission denied', 'not permitted', 'not allowed', 'forbidden',
        'unauthorized', 'unauthorised', 'insufficient permission',
        'missing permission', 'op_allowed', ' 403'],
    "You don't have permission to do that here. Ask an admin if you need it.",
  ),
  _Rule(
    ['not found', 'no such file', 'does not exist', "doesn't exist",
        'no longer exists', 'unknown server', 'unknown channel', ' 404'],
    "Hollow couldn't find that. It may have been removed, so refresh and try "
        'again.',
  ),
  _Rule(
    ['already exists', 'already taken', 'is taken', 'duplicate',
        'unique constraint'],
    'That already exists. Try a different name.',
  ),
  _Rule(
    ['too large', 'too big', 'too long', 'exceeds'],
    "That's too large. Try something smaller.",
  ),
  _Rule(
    ['invalid', 'malformed', 'failed to parse', 'parse error',
        'could not parse', 'bad request', 'not valid', 'unexpected character',
        ' 400'],
    "Hollow couldn't use what was entered. Check it and try again.",
  ),
];

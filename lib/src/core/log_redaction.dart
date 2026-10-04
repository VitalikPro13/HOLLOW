import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Rewrites a diagnostics export so it names nobody: peer ids, long hex and
/// UUID ids, IPv4 addresses and the home folder become short tags. A tag is a
/// keyed hash under a key drawn per export, so one export still lines up with
/// itself while no tag can be checked against a known id.
class LogRedactor {
  LogRedactor([List<int>? key]) : _key = key ?? _randomKey();

  final List<int> _key;

  static List<int> _randomKey() {
    final rng = Random.secure();
    return List<int>.generate(32, (_) => rng.nextInt(256));
  }

  static final _home = RegExp(r'([A-Za-z]:\\Users\\|/Users/|/home/)[^\\/\s]+',
      caseSensitive: false);
  static final _peerId = RegExp(r'12D3KooW[1-9A-HJ-NP-Za-km-z]+');
  static final _uuid = RegExp(
      r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');
  static final _hex = RegExp(r'\b[0-9a-fA-F]{16,}\b');
  static final _ipv4 = RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b');

  String redact(String text) {
    var out = text.replaceAllMapped(_home, (m) => '${m[1]}~');
    out = out.replaceAllMapped(_peerId, (m) => 'peer#${_tag(m[0]!)}');
    out = out.replaceAllMapped(_uuid, (m) => 'id#${_tag(m[0]!)}');
    out = out.replaceAllMapped(_hex, (m) => 'id#${_tag(m[0]!)}');
    out = out.replaceAllMapped(_ipv4, (m) {
      final ip = m[0]!;
      // Loopback and the unspecified address say nothing about anyone.
      if (ip.startsWith('127.') || ip == '0.0.0.0') return ip;
      return 'ip#${_tag(ip)}';
    });
    return out;
  }

  String _tag(String value) =>
      Hmac(sha256, _key).convert(utf8.encode(value)).toString().substring(0, 6);
}

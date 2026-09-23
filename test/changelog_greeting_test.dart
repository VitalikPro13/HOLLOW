import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/core/greeting.dart';

void main() {
  group('parseChangelog', () {
    const text = 'v0.11.1 - Linux Call Audio & Relays\r\n'
        '\r\n'
        'LINUX\r\n'
        '\r\n'
        '- Calls carry audio again\r\n'
        '- Fixed a crash\r\n'
        '\r\n'
        'SERVERS & CHANNELS\r\n'
        '\r\n'
        '- Voice channels got access\r\n'
        '\r\n'
        'v0.11 - Call Resilience\r\n'
        '\r\n'
        'BREAKING CHANGE: 0.11 cannot share a server with 0.10.1.\r\n'
        '\r\n'
        'SELF-HOSTING\r\n'
        '\r\n'
        '- One settings file\r\n';

    test('splits releases, sections, bullets and notes', () {
      final r = parseChangelog(text);
      expect(r, hasLength(2));
      expect(r[0].version, '0.11.1');
      expect(r[0].title, 'Linux Call Audio & Relays');
      expect(r[0].sections.map((s) => s.name),
          ['Linux', 'Servers & Channels']);
      expect(r[0].sections[0].items, ['Calls carry audio again', 'Fixed a crash']);
      expect(r[1].notes.single, startsWith('BREAKING CHANGE'));
      expect(r[1].sections.single.name, 'Self-Hosting');
    });

    test('a two-part version matches its .0 app version', () {
      final r = parseChangelog(text);
      expect(r[1].describes('0.11.0'), isTrue);
      expect(r[0].describes('0.11.1'), isTrue);
      expect(r[0].describes('0.11.0'), isFalse);
    });

    test('the real changelog parses and its newest block has sections', () {
      final real = parseChangelog(File('changelog.txt').readAsStringSync());
      expect(real, isNotEmpty);
      expect(real.first.sections, isNotEmpty);
      expect(real.first.sections.expand((s) => s.items), isNotEmpty);
    });
  });

  group('greetingFor', () {
    DateTime at(int h) => DateTime(2026, 9, 23, h, 30);

    test('follows the local clock in four blocks', () {
      expect(greetingFor(at(0)), 'Good night');
      expect(greetingFor(at(5)), 'Good night');
      expect(greetingFor(at(6)), 'Good morning');
      expect(greetingFor(at(12)), 'Good afternoon');
      expect(greetingFor(at(18)), 'Good evening');
      expect(greetingFor(at(23)), 'Good evening');
    });

    test('knows when it next changes', () {
      expect(nextGreetingChange(at(7)), DateTime(2026, 9, 23, 12));
      expect(nextGreetingChange(at(20)), DateTime(2026, 9, 24));
    });
  });
}

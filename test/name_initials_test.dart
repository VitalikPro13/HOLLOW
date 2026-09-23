import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/name_initials.dart';

void main() {
  group('peerInitials', () {
    test('uses the display name when one is set', () {
      expect(peerInitials('AnonListen', '12D3KooWAbCdEf'), 'AN');
      expect(peerInitials('mac mini', '12D3KooWAbCdEf'), 'MM');
    });

    test('falls back to the END of the peer id, never the shared 12 prefix',
        () {
      expect(peerInitials('', '12D3KooWAbCdEf'), 'EF');
      expect(peerInitials('   ', '12D3KooWXyZ9q'), '9Q');
    });

    test('a too-short id still renders something', () {
      expect(peerInitials('', 'a'), '??');
    });
  });

  group('initialsFromName', () {
    test('trims before taking letters', () {
      expect(initialsFromName('  bob'), 'BO');
    });

    test('does not split a leading emoji in half', () {
      expect(initialsFromName('\u{1F600}x'), '\u{1F600}X');
    });
  });
}

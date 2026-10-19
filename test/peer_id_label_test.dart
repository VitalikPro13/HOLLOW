import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/peer_id_label.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';

const _id = '12D3KooWQx9mzS4zJp1rT8bH2kLcV7nYwE5aGfD3uT7iS4F';

void main() {
  group('shortPeerLabel', () {
    test('keeps the start and the ending around one ellipsis', () {
      expect(shortPeerLabel(_id), '12D3…fD3uT7iS4F');
    });

    test('an id short enough to show whole stays whole', () {
      expect(shortPeerLabel(''), '');
      expect(shortPeerLabel('12D3KooWabc'), '12D3KooWabc');
      expect(shortPeerLabel('1234567890123456'), '1234567890123456');
    });

    test('the first length that shortens still ends with the last 6', () {
      const id = '12345678901234567';
      expect(shortPeerLabel(id), '1234…8901234567');
    });

    test('two people sharing the common start differ by their label', () {
      const a = '12D3KooWAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaaaa01';
      const b = '12D3KooWAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAaaaa02';
      expect(shortPeerLabel(a), isNot(shortPeerLabel(b)));
    });
  });

  group('fitPeerId', () {
    bool Function(String) maxChars(int n) => (s) => s.length <= n;

    test('the whole id when it fits', () {
      expect(fitPeerId(_id, (_) => true), _id);
      expect(fitPeerId(_id, maxChars(_id.length)), _id);
    });

    test('one character short drops the middle, never the ending', () {
      final shown = fitPeerId(_id, maxChars(_id.length - 1));
      expect(shown.length, _id.length - 1);
      expect(shown, contains('…'));
      expect(_id.endsWith(shown.split('…').last), isTrue);
      expect(_id.startsWith(shown.split('…').first), isTrue);
    });

    test('uses all the room it has', () {
      for (final room in [8, 12, 15, 20, 30, 40]) {
        final shown = fitPeerId(_id, maxChars(room));
        expect(shown.length, room, reason: 'room $room gave "$shown"');
        expect(shown.endsWith('T7iS4F'), isTrue, reason: shown);
      }
    });

    test('the ending keeps at least half of what is shown', () {
      final shown = fitPeerId(_id, maxChars(21));
      final parts = shown.split('…');
      expect(parts.last.length, greaterThanOrEqualTo(parts.first.length));
      expect(parts.first.length + parts.last.length, 20);
    });

    test('no room at all still shows the last 6', () {
      expect(fitPeerId(_id, maxChars(0)), '…T7iS4F');
      expect(fitPeerId(_id, maxChars(3)), '…T7iS4F');
    });

    test('a short id is never padded or cut', () {
      expect(fitPeerId('abc', maxChars(0)), 'abc');
      expect(fitPeerId('', maxChars(0)), '');
    });
  });

  test('a person with no name is named by the start and the ending', () {
    expect(displayNameForPeer(null, _id), '12D3…fD3uT7iS4F');
    expect(serverDisplayNameForPeer(null, _id), '12D3…fD3uT7iS4F');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/peer_id_label.dart';
import 'package:hollow/src/core/services/push_hints_cache.dart';

void main() {
  const master = '12D3KooWQx9mzS4zJp1rT8bH2kLcV7nYwE5aGfD3uT7iS4F';

  test('a friend with no name and no avatar still gets a hint', () {
    final entry = PushHintsCache.hintEntry(master: master);
    expect(entry['master'], master);
    expect(entry['name'], '12D3…fD3uT7iS4F');
    expect(entry.containsKey('avatar'), isFalse);
  });

  test('a chosen name wins over the short id', () {
    final entry = PushHintsCache.hintEntry(
      master: master,
      name: 'Faust',
      avatarPath: '/g/push_hints/x.img',
    );
    expect(entry['name'], 'Faust');
    expect(entry['avatar'], '/g/push_hints/x.img');
  });

  test('an empty name falls back to the short id', () {
    expect(
      PushHintsCache.hintEntry(master: master, name: '')['name'],
      '12D3…fD3uT7iS4F',
    );
  });

  test('short ids tell people apart by their ending', () {
    expect(shortPeerLabel(master), '12D3…fD3uT7iS4F');
    expect(shortPeerLabel('12D3KooWabc'), '12D3KooWabc');
  });
}

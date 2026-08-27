import 'package:flutter_test/flutter_test.dart';

/// The bug this file exists for (field-caught 2026-08-27): `enableForReceiver`
/// checked its map for an existing cryptor, then awaited the native create,
/// then inserted. Two callers arriving together BOTH passed the guard, BOTH
/// created a native cryptor on the same receiver, and the map kept only the
/// second. The first stayed attached natively and the two fought over the same
/// frames. The recovery log shows it plainly: two "Receiver decryption enabled"
/// lines for one key with no drop between them, then DecryptionFailed and
/// MissingKey.
///
/// The real cryptors need a live WebRTC stack, so what is pinned here is the
/// serialization primitive itself: the property that made the bug possible was
/// check-then-act across an await, and the fix is that queued work never
/// interleaves.
class _Serializer {
  Future<void> _mutations = Future<void>.value();

  Future<T> serialize<T>(Future<T> Function() op) {
    final result = _mutations.then((_) => op());
    _mutations = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}

void main() {
  test('a check-then-act across an await double-creates without a lock', () {
    // Pins WHY the lock is needed, so nobody "simplifies" it away later.
    final map = <String, int>{};
    var creates = 0;

    Future<void> unlockedEnable() async {
      if (map.containsKey('k')) return;
      await Future<void>.delayed(Duration.zero); // the native create
      creates++;
      map['k'] = creates;
    }

    return Future.wait([unlockedEnable(), unlockedEnable()]).then((_) {
      expect(creates, 2,
          reason: 'both callers passed the guard before either inserted');
    });
  });

  test('serialized, the same pair creates exactly one', () async {
    final lock = _Serializer();
    final map = <String, int>{};
    var creates = 0;

    Future<void> enable() => lock.serialize(() async {
          if (map.containsKey('k')) return;
          await Future<void>.delayed(Duration.zero);
          creates++;
          map['k'] = creates;
        });

    await Future.wait([enable(), enable()]);
    expect(creates, 1);
  });

  test('a whole ladder runs without another ladder interleaving', () async {
    final lock = _Serializer();
    final events = <String>[];

    Future<void> ladder(String tag) => lock.serialize(() async {
          events.add('$tag-drop');
          await Future<void>.delayed(Duration.zero);
          events.add('$tag-create');
          await Future<void>.delayed(Duration.zero);
          events.add('$tag-index');
        });

    await Future.wait([ladder('a'), ladder('b')]);
    expect(events, [
      'a-drop', 'a-create', 'a-index',
      'b-drop', 'b-create', 'b-index',
    ], reason: 'a drop must never be separated from its re-create: that is how '
        'a receiver ends up with two cryptors or none');
  });

  test('one thrown operation does not wedge the queue for the whole call',
      () async {
    final lock = _Serializer();
    final done = <String>[];

    final boom = lock.serialize(() async => throw StateError('native failed'));
    await boom.then((_) {}, onError: (Object _) {});
    await lock.serialize(() async => done.add('after'));

    expect(done, ['after']);
  });
}

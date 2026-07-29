import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/gif_library_provider.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/rust/api/gifs.dart' as gifs_api;

/// GIF library (recents / favourites / lists). Persistence itself is a
/// fire-and-forget settings write that no-ops without an open store, so these
/// exercise the in-memory model plus the encode/decode round trip.

const _base = kDefaultGifProxyUrl;

gifs_api.GifItem _item(String id, {int w = 200, int h = 150, String? still}) =>
    gifs_api.GifItem(
      id: id,
      w: w,
      h: h,
      title: 'title $id',
      stillUrl: still ?? '$_base' 'm/$id.still.webp',
      smUrl: '$_base' 'm/$id.sm.webp',
      fullUrl: '$_base' 'f/$id',
    );

GifLibraryNotifier _notifier(ProviderContainer c) =>
    c.read(gifLibraryProvider.notifier);

ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('SavedGif', () {
    test('stores media paths RELATIVE to the proxy base', () {
      final saved = SavedGif.fromItem(_item('abc'), _base)!;
      expect(saved.stillPath, 'm/abc.still.webp');
      expect(saved.smPath, 'm/abc.sm.webp');
      // …and rebuilds absolute URLs against whatever base is active, so a
      // self-hoster who moves proxies keeps their favourites.
      final moved = saved.toItem('https://gifs.example.org/');
      expect(moved.stillUrl, 'https://gifs.example.org/m/abc.still.webp');
    });

    test('keeps off-base https URLs whole (a direct-mode pick)', () {
      // Direct mode: Klipy CDN paths are opaque and cannot be rebuilt from an
      // id, so the absolute URL is stored as-is. Rust host-checked it at parse
      // time, and GifLibraryNotifier.revalidate re-checks it against the
      // CURRENT configuration on every source change.
      final saved = SavedGif.fromItem(_item('abc'), 'https://other.example/')!;
      expect(saved.stillPath, '${_base}m/abc.still.webp');
      expect(saved.toItem('https://other.example/').stillUrl,
          '${_base}m/abc.still.webp',
          reason: 'an absolute location ignores the base');
    });

    test('refuses a bogus relative path shape', () {
      // Under the base, so it must satisfy the m/<id>.<variant>.<ext> shape.
      expect(
        SavedGif.fromItem(
            _item('abc', still: '${_base}evil/../etc.still.webp'), _base),
        isNull,
      );
      // Not under the base and not https either — neither form fits.
      expect(
        SavedGif.fromItem(_item('abc', still: 'http://evil.example/x.webp'),
            'https://other.example/'),
        isNull,
      );
    });

    test('round-trips through JSON and drops unreadable rows', () {
      final lib = GifLibrary(
        favorites: [SavedGif.fromItem(_item('abc'), _base)!],
        recents: [SavedGif.fromItem(_item('def'), _base)!],
        collections: const [
          GifCollection(id: 'l1', name: 'Reactions', gifIds: ['abc'])
        ],
      );
      final back = GifLibrary.decode(lib.encode());
      expect(back.favorites.single.id, 'abc');
      expect(back.recents.single.id, 'def');
      expect(back.collections.single.name, 'Reactions');
      expect(back.collections.single.gifIds, ['abc']);

      // Garbage never takes the library with it (same reasoning as
      // #[serde(default)] on the Rust structs).
      expect(GifLibrary.decode('not json').favorites, isEmpty);
      expect(
        GifLibrary.decode('{"favorites":[{"id":"x"},{"nope":1}]}').favorites,
        isEmpty,
      );
    });

    test('a plaintext-http location can never survive a decode', () {
      // https-or-relative is the whole vocabulary: anything else is refused
      // before the thumbnail cache could ever be handed it.
      const raw =
          '{"favorites":[{"id":"a","w":1,"h":1,"p":"http://evil.example/x.webp","s":"m/a.sm.webp"}]}';
      expect(GifLibrary.decode(raw).favorites, isEmpty);
    });

    test('an absolute location decodes but stays hidden until permitted', () {
      // Direct-mode rows survive the round trip (dropping them would lose a
      // user's favourites on a mode switch)…
      const raw =
          '{"favorites":[{"id":"a","w":1,"h":1,"p":"https://static.klipy.com/a.jpg","s":"https://static.klipy.com/a.webp"}]}';
      final lib = GifLibrary.decode(raw);
      expect(lib.favorites.single.id, 'a');
      expect(lib.visibleFavorites.single.id, 'a');

      // …but the moment Rust says that location may not be fetched in the
      // current configuration — going back to the proxy is exactly that case
      // — nothing renders it, and nothing is deleted either.
      final hidden = lib.copyWith(
          hiddenLocations: const {'https://static.klipy.com/a.jpg'});
      expect(hidden.visibleFavorites, isEmpty);
      expect(hidden.favoritesIn(null), isEmpty);
      expect(hidden.favorites.single.id, 'a', reason: 'hidden, not dropped');
      expect(hidden.encode(), lib.encode(),
          reason: 'visibility is never persisted');
    });
  });

  group('GifLibraryNotifier', () {
    test('noteUsed keeps recents newest-first and deduped', () {
      final c = _container();
      final n = _notifier(c);
      n.noteUsed(_item('a'));
      n.noteUsed(_item('b'));
      n.noteUsed(_item('a'));
      expect(c.read(gifLibraryProvider).recents.map((g) => g.id), ['a', 'b']);
    });

    test('toggleFavorite adds, reports state, and removes', () {
      final c = _container();
      final n = _notifier(c);
      expect(n.toggleFavorite(_item('a')), isTrue);
      expect(c.read(gifLibraryProvider).isFavorite('a'), isTrue);
      expect(n.toggleFavorite(_item('a')), isFalse);
      expect(c.read(gifLibraryProvider).isFavorite('a'), isFalse);
    });

    test('lists sort favourites and drop the GIF when it is unfavourited', () {
      final c = _container();
      final n = _notifier(c);
      n.toggleFavorite(_item('a'));
      final id = n.createCollection('  Reactions  ')!;
      expect(c.read(gifLibraryProvider).collections.single.name, 'Reactions');

      n.setInCollection(id, 'a', true);
      expect(c.read(gifLibraryProvider).favoritesIn(id).single.id, 'a');
      // Adding twice is idempotent.
      n.setInCollection(id, 'a', true);
      expect(c.read(gifLibraryProvider).collections.single.gifIds, ['a']);

      // A list only sorts FAVOURITES — a non-favourite cannot be added.
      n.setInCollection(id, 'ghost', true);
      expect(c.read(gifLibraryProvider).collections.single.gifIds, ['a']);

      // Unfavouriting evicts it from every list, so a re-favourite is clean.
      n.toggleFavorite(_item('a'));
      expect(c.read(gifLibraryProvider).collections.single.gifIds, isEmpty);
    });

    test('favoritesIn(null) is everything; an unknown list is empty', () {
      final c = _container();
      final n = _notifier(c);
      n.toggleFavorite(_item('a'));
      n.toggleFavorite(_item('b'));
      expect(c.read(gifLibraryProvider).favoritesIn(null).length, 2);
      expect(c.read(gifLibraryProvider).favoritesIn('nope'), isEmpty);
    });

    test('list names are trimmed, clipped, and never empty', () {
      final c = _container();
      final n = _notifier(c);
      expect(n.createCollection('   '), isNull);
      final id = n.createCollection('x' * 100)!;
      expect(c.read(gifLibraryProvider).collections.single.name.length,
          kMaxGifListNameLength);
      n.renameCollection(id, '  Cats ');
      expect(c.read(gifLibraryProvider).collections.single.name, 'Cats');
      n.renameCollection(id, '   ');
      expect(c.read(gifLibraryProvider).collections.single.name, 'Cats');
    });

    test('collection ids never collide after a delete', () {
      final c = _container();
      final n = _notifier(c);
      final a = n.createCollection('a')!;
      final b = n.createCollection('b')!;
      n.deleteCollection(a);
      final d = n.createCollection('d')!;
      expect(d, isNot(b));
      expect(c.read(gifLibraryProvider).collections.map((x) => x.id).toSet(),
          {b, d});
    });

    test('removeRecent and clearRecents leave favourites alone', () {
      final c = _container();
      final n = _notifier(c);
      n.noteUsed(_item('a'));
      n.toggleFavorite(_item('a'));
      n.removeRecent('a');
      expect(c.read(gifLibraryProvider).recents, isEmpty);
      expect(c.read(gifLibraryProvider).isFavorite('a'), isTrue);
      n.noteUsed(_item('b'));
      n.clearRecents();
      expect(c.read(gifLibraryProvider).recents, isEmpty);
      expect(c.read(gifLibraryProvider).favorites.single.id, 'a');
    });
  });
}

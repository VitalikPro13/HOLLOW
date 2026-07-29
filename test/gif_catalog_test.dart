import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/rust/api/gifs.dart' as gifs_api;

/// GifCatalog unit tests.
///
/// These fake ONLY the raw-FFI seam ([GifCatalog.fetchPage] /
/// [GifCatalog.fetchCategories]) so the caching / in-flight / timeout chain
/// wrapped around it is the code under test. The picker's widget tests fake
/// `page()` wholesale, and stayed green through a bug that lived entirely in
/// that wrapper: `whenComplete(() => _inflight.remove(key))` returns the
/// removed Future — the very future being completed — and whenComplete waits
/// for an action-returned Future, so the future deadlocked on itself. The
/// inner `.then` still ran (the RAM cache warmed, so reopening the picker
/// showed results) while every caller's `.then` never fired.
///
/// MUST be plain `test()`, never `testWidgets()`: FakeAsync cannot distinguish
/// "waiting forever" from "waiting", so the hang only reproduces in real time.

gifs_api.GifItem _item(String id) => gifs_api.GifItem(
      id: id,
      w: 200,
      h: 150,
      title: id,
      stillUrl: 'https://proxy.test/gifs/m/$id.still.webp',
      smUrl: 'https://proxy.test/gifs/m/$id.sm.webp',
      fullUrl: 'https://proxy.test/gifs/f/$id',
    );

gifs_api.GifPage _page(List<gifs_api.GifItem> items) =>
    gifs_api.GifPage(items: items, page: 1, hasNext: false, backoffUntil: 0);

class _SeamCatalog extends GifCatalog {
  int pageCalls = 0;
  String? lastRating;
  int categoryCalls = 0;
  final _gates = <String, Completer<gifs_api.GifPage>>{};

  Completer<gifs_api.GifPage> _gate(String q, int p) =>
      _gates.putIfAbsent('$q|$p', Completer.new);

  @override
  Future<gifs_api.GifPage> fetchPage(String query, int page, String rating) {
    pageCalls++;
    lastRating = rating;
    return _gate(query, page).future;
  }

  @override
  Future<List<String>> fetchCategories() async {
    categoryCalls++;
    return const ['reactions', 'cats'];
  }

  void answer(String q, int p, gifs_api.GifPage value) =>
      _gate(q, p).complete(value);
}

/// A caller that hangs forever is the failure mode under test, so never await
/// bare — always bound it.
Future<T> _bounded<T>(Future<T> f) =>
    f.timeout(const Duration(seconds: 5), onTimeout: () {
      fail('future never completed for its caller (whenComplete self-wait?)');
    });

void main() {
  test('page(): the future handed to the caller actually completes', () async {
    final catalog = _SeamCatalog();
    final pending = catalog.page('', 1, 'pg');
    catalog.answer('', 1, _page([_item('t1')]));
    final result = await _bounded(pending);
    expect(result.items.single.id, 't1');
  });

  test('page(): every concurrent caller of one in-flight query completes',
      () async {
    final catalog = _SeamCatalog();
    // The picker and the boot prefetch both request trending page 1.
    final a = catalog.page('', 1, 'pg');
    final b = catalog.page('', 1, 'pg');
    expect(catalog.pageCalls, 1, reason: 'in-flight dedup');
    catalog.answer('', 1, _page([_item('t1')]));
    expect((await _bounded(a)).items.single.id, 't1');
    expect((await _bounded(b)).items.single.id, 't1');
  });

  test('page(): a settled query frees its in-flight slot', () async {
    final catalog = _SeamCatalog();
    final first = catalog.page('cat', 1, 'pg');
    // Empty result: deliberately NOT cached, so the retry must re-fetch
    // rather than be served from _pages.
    catalog.answer('cat', 1, _page(const []));
    expect((await _bounded(first)).items, isEmpty);

    final retry = catalog.page('cat', 1, 'pg');
    expect(catalog.pageCalls, 2, reason: 'slot freed, so a retry re-fetches');
    // The gate for cat|1 is already completed, so the retry resolves off it.
    expect((await _bounded(retry)).items, isEmpty);
  });

  test('page(): a non-empty result warms peek() for the next open', () async {
    final catalog = _SeamCatalog();
    expect(catalog.peek('', 1, 'pg'), isNull);
    final pending = catalog.page('', 1, 'pg');
    catalog.answer('', 1, _page([_item('t1')]));
    await _bounded(pending);
    expect(catalog.peek('', 1, 'pg')?.items.single.id, 't1',
        reason: 'a warm reopen must render with no spinner frame');
    // A warm hit must not reach the proxy again.
    expect((await _bounded(catalog.page('', 1, 'pg'))).items.single.id, 't1');
    expect(catalog.pageCalls, 1);
  });

  test('page(): normalizes the query key (trim + case)', () async {
    final catalog = _SeamCatalog();
    final pending = catalog.page('  CAT ', 1, 'pg');
    catalog.answer('cat', 1, _page([_item('c1')]));
    expect((await _bounded(pending)).items.single.id, 'c1');
    expect(catalog.peek('cat', 1, 'pg'), isNotNull);
  });

  test('categories(): completes, caches, and dedups', () async {
    final catalog = _SeamCatalog();
    expect(await _bounded(catalog.categories()), ['reactions', 'cats']);
    expect(await _bounded(catalog.categories()), ['reactions', 'cats']);
    expect(catalog.categoryCalls, 1);
  });

  test('page(): a failing fetch propagates to the caller, not a hang',
      () async {
    final catalog = _SeamCatalog();
    final pending = catalog.page('dog', 1, 'pg');
    catalog._gate('dog', 1).completeError(Exception('proxy down'));
    await expectLater(_bounded(pending), throwsA(isA<Exception>()));
    // …and the slot is freed so the picker's Retry button can re-fetch.
    final retry = catalog.page('dog', 1, 'pg');
    expect(catalog.pageCalls, 2);
    await expectLater(_bounded(retry), throwsA(isA<Exception>()));
  });

  test('page(): the rating is part of the cache key', () async {
    final catalog = _SeamCatalog();
    final pending = catalog.page('cat', 1, 'pg');
    catalog.answer('cat', 1, _page([_item('c1')]));
    await _bounded(pending);
    expect(catalog.peek('cat', 1, 'pg'), isNotNull);
    // Raising the rating must ask again, never re-serve the milder page.
    expect(catalog.peek('cat', 1, 'r'), isNull);
    catalog.page('cat', 1, 'r');
    expect(catalog.pageCalls, 2);
    expect(catalog.lastRating, 'r', reason: 'the rating reaches the FFI seam');
  });

  test('clear(): a GIF source change drops every cached page', () async {
    final catalog = _SeamCatalog();
    final pending = catalog.page('cat', 1, 'pg');
    catalog.answer('cat', 1, _page([_item('c1')]));
    await _bounded(pending);
    expect(await _bounded(catalog.categories()), isNotEmpty);
    // Proxy and direct mode hand out different URLs for the same GIF id, so
    // switching sources must invalidate everything, not just re-key it.
    catalog.clear();
    expect(catalog.peek('cat', 1, 'pg'), isNull);
    await _bounded(catalog.categories());
    expect(catalog.categoryCalls, 2);
  });

  group('gifAutoplayProvider', () {
    test('defaults ON, and a failed load never flips it', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(gifAutoplayProvider), isTrue);
      // No FFI in a plain test: loadCached must swallow and leave the
      // default standing rather than reading `null` as "off".
      await c.read(gifAutoplayProvider.notifier).loadCached();
      expect(c.read(gifAutoplayProvider), isTrue);
    });

    test('setEnabled flips it (the persist write is best-effort)', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await c.read(gifAutoplayProvider.notifier).setEnabled(false);
      expect(c.read(gifAutoplayProvider), isFalse);
      await c.read(gifAutoplayProvider.notifier).setEnabled(true);
      expect(c.read(gifAutoplayProvider), isTrue);
    });
  });

  group('clampGifRating', () {
    test('caps R at PG-13 for a server that is not flagged NSFW', () {
      expect(clampGifRating('r', serverAllowsNsfw: false), 'pg-13');
      expect(clampGifRating('r', serverAllowsNsfw: true), 'r');
    });

    test('leaves the milder ratings alone either way', () {
      for (final r in ['g', 'pg', 'pg-13']) {
        expect(clampGifRating(r, serverAllowsNsfw: false), r);
        expect(clampGifRating(r, serverAllowsNsfw: true), r);
      }
    });
  });
}

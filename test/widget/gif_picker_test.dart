import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/gif_library_provider.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/rust/api/gifs.dart' as gifs_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart';

/// GIF picker widget tests: debounce + in-flight seq guard, teardown while a
/// search is in flight, and the error state. The catalog is faked through
/// [gifCatalogProvider]; thumbnail loads fail silently in the test binding
/// (mock HttpClient) so cells render their placeholders.

/// Media URLs must sit under the ACTIVE proxy base or the library refuses to
/// save them (SavedGif stores proxy-relative paths).
gifs_api.GifItem _item(String id, [String title = '']) => gifs_api.GifItem(
      id: id,
      w: 200,
      h: 150,
      title: title,
      stillUrl: '${kDefaultGifProxyUrl}m/$id.still.webp',
      smUrl: '${kDefaultGifProxyUrl}m/$id.sm.webp',
      fullUrl: '${kDefaultGifProxyUrl}f/$id',
    );

gifs_api.GifPage _page(List<gifs_api.GifItem> items) => gifs_api.GifPage(
    items: items, page: 1, hasNext: false, backoffUntil: 0);

class _FakeCatalog extends GifCatalog {
  final pending = <String, Completer<gifs_api.GifPage>>{};
  final queries = <String>[];
  final ratings = <String>[];

  @override
  gifs_api.GifPage? peek(String query, int page, String rating) => null;

  @override
  Future<gifs_api.GifPage> page(String query, int page, String rating) {
    final key = '${query.trim().toLowerCase()}|$page';
    queries.add(key);
    ratings.add(rating);
    final c = pending.putIfAbsent(key, Completer.new);
    return c.future;
  }

  @override
  Future<List<String>> categories() async => const ['reactions', 'cats'];
}

/// Fakes ONLY the raw-FFI seam, so the picker drives the REAL GifCatalog
/// caching / in-flight / timeout chain. [_FakeCatalog] above replaces `page()`
/// wholesale, which is exactly how a deadlock inside that chain
/// (`whenComplete(() => _inflight.remove(key))` waiting on its own future)
/// once shipped with all three picker tests green.
class _SeamCatalog extends GifCatalog {
  final pending = <String, Completer<gifs_api.GifPage>>{};
  final fetches = <String>[];

  @override
  Future<gifs_api.GifPage> fetchPage(String query, int page, String rating) {
    fetches.add('$query|$page');
    return pending.putIfAbsent('$query|$page', Completer.new).future;
  }

  @override
  Future<List<String>> fetchCategories() async => const ['reactions', 'cats'];
}

Widget _host({required void Function(BuildContext) onOpen}) {
  return MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => onOpen(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

/// Opens the picker over a caller-owned container, so a test can seed the GIF
/// library (recents/favourites) before the first frame.
Future<void> _openWith(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: _host(
      onOpen: (ctx) => showGifPicker(
        context: ctx,
        anchorPosition: const Offset(300, 300),
        onSelect: (_) {},
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
}

ProviderContainer _container(GifCatalog catalog) {
  final c = ProviderContainer(
      overrides: [gifCatalogProvider.overrideWithValue(catalog)]);
  addTearDown(c.dispose);
  return c;
}

/// Desktop reveals the star on hover, so a test has to actually hover.
Future<void> _hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
}

void main() {
  testWidgets('picker: trending renders, search debounces + seq-guards',
      (tester) async {
    final catalog = _FakeCatalog();
    final tokens = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [gifCatalogProvider.overrideWithValue(catalog)],
      child: _host(
        onOpen: (ctx) => showGifPicker(
          context: ctx,
          anchorPosition: const Offset(300, 300),
          onSelect: tokens.add,
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.byType(GifPickerBody), findsOneWidget);
    expect(catalog.queries, contains('|1')); // trending requested at open

    catalog.pending['|1']!.complete(_page([_item('t1', 'trending one')]));
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF trending one'), findsOneWidget);

    // Type "cat", then "catz" before the 250ms debounce fires — only the
    // final query may reach the catalog.
    await tester.enterText(find.byType(TextField).first, 'cat');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField).first, 'catz');
    await tester.pump(const Duration(milliseconds: 400));
    expect(catalog.queries, isNot(contains('cat|1')));
    expect(catalog.queries, contains('catz|1'));

    catalog.pending['catz|1']!.complete(_page([_item('c1', 'catz one')]));
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF catz one'), findsOneWidget);

    // Barrier tap dismisses.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    // The picker plays a scale+fade exit before its overlay entry is
    // removed, so dismissal is no longer a single-frame affair.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(GifPickerBody), findsNothing);
    expect(tokens, isEmpty);
  });

  testWidgets('picker: renders results through the REAL catalog chain',
      (tester) async {
    final catalog = _SeamCatalog();
    await tester.pumpWidget(ProviderScope(
      overrides: [gifCatalogProvider.overrideWithValue(catalog)],
      child: _host(
        onOpen: (ctx) => showGifPicker(
          context: ctx,
          anchorPosition: const Offset(300, 300),
          onSelect: (_) {},
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    expect(catalog.fetches, contains('|1'));

    catalog.pending['|1']!.complete(_page([_item('t1', 'trending one')]));
    await tester.pump();
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF trending one'), findsOneWidget,
        reason: 'the caller-facing future of the real page() must resolve');

    // A search rides the same chain, and its result must reach the grid too.
    await tester.enterText(find.byType(TextField).first, 'catz');
    await tester.pump(const Duration(milliseconds: 400));
    expect(catalog.fetches, contains('catz|1'));
    catalog.pending['catz|1']!.complete(_page([_item('c1', 'catz one')]));
    await tester.pump();
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF catz one'), findsOneWidget);

    // Reopening must be served warm from the cache the chain populated,
    // without a second proxy hit.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    // The picker plays a scale+fade exit before its overlay entry is
    // removed, so dismissal is no longer a single-frame affair.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('open'));
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF trending one'), findsOneWidget);
    expect(catalog.fetches.where((f) => f == '|1').length, 1);

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    // The picker plays a scale+fade exit before its overlay entry is
    // removed, so dismissal is no longer a single-frame affair.
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets('picker: teardown while a search is in flight does not crash',
      (tester) async {
    final catalog = _FakeCatalog();
    await tester.pumpWidget(ProviderScope(
      overrides: [gifCatalogProvider.overrideWithValue(catalog)],
      child: _host(
        onOpen: (ctx) => showGifPicker(
          context: ctx,
          anchorPosition: const Offset(300, 300),
          onSelect: (_) {},
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'dog');
    await tester.pump(const Duration(milliseconds: 300));
    expect(catalog.queries, contains('dog|1'));

    // Dismiss with the search still pending, then resolve it late — the
    // mounted guard must swallow the result.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    // The picker plays a scale+fade exit before its overlay entry is
    // removed, so dismissal is no longer a single-frame affair.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(GifPickerBody), findsNothing);
    catalog.pending['dog|1']!.complete(_page([_item('d1')]));
    await tester.pump();
    // Trending is still pending too — resolve so nothing leaks into the
    // next test's zone.
    catalog.pending['|1']!.complete(_page(const []));
    await tester.pump();
  });

  testWidgets('picker: tabs replaced the prefilled category chips',
      (tester) async {
    final catalog = _FakeCatalog();
    await _openWith(tester, _container(catalog));

    expect(find.text('Popular'), findsOneWidget);
    expect(find.text('Favourites'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
    // The old chip row searched a prefilled word list — gone.
    expect(find.text('reactions'), findsNothing);
    expect(find.text('cats'), findsNothing);

    // Searching does NOT remove the tabs — a row that vanishes as you type
    // shifts the grid and hides where you came from. They just go unselected.
    await tester.enterText(find.byType(TextField).first, 'dog');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Popular'), findsOneWidget);
    expect(find.text('Favourites'), findsOneWidget);
    expect(find.text('Recent'), findsOneWidget);
  });

  testWidgets('picker: tapping a tab is how you leave a search',
      (tester) async {
    final catalog = _FakeCatalog();
    await _openWith(tester, _container(catalog));

    await tester.enterText(find.byType(TextField).first, 'dog');
    await tester.pump(const Duration(milliseconds: 400));
    expect(catalog.queries, contains('dog|1'));

    // Popular is ALREADY the active tab — tapping it while searching must
    // still act (clear the field), not early-return as a no-op.
    await tester.tap(find.text('Popular'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.widgetWithText(TextField, 'dog'), findsNothing,
        reason: 'the search field clears');
    expect(catalog.queries.last, '|1', reason: 'back on trending');
  });

  testWidgets('picker: starring a GIF files it under Favourites',
      (tester) async {
    final catalog = _FakeCatalog();
    final container = _container(catalog);
    await _openWith(tester, container);
    catalog.pending['|1']!.complete(_page([_item('t1', 'trending one')]));
    await tester.pump();

    final cell = find.bySemanticsLabel('Insert GIF trending one');
    expect(cell, findsOneWidget);
    // Hover-revealed on desktop so the grid stays clean.
    expect(find.bySemanticsLabel('Add GIF to favourites'), findsNothing);
    await _hover(tester, cell);
    await tester.tap(find.bySemanticsLabel('Add GIF to favourites'));
    await tester.pump();

    expect(container.read(gifLibraryProvider).isFavorite('t1'), isTrue);
    // Now it stays visible without hover, as the "saved" marker.
    expect(find.bySemanticsLabel('Remove GIF from favourites'), findsOneWidget);

    await tester.tap(find.text('Favourites'));
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF trending one'), findsOneWidget);
    // The favourite renders straight from the library — no proxy hit.
    expect(catalog.queries.where((q) => q != '|1'), isEmpty);
  });

  testWidgets('picker: empty Favourites and Recent explain themselves',
      (tester) async {
    final catalog = _FakeCatalog();
    await _openWith(tester, _container(catalog));

    await tester.tap(find.text('Favourites'));
    await tester.pump();
    expect(find.textContaining('No favourites yet'), findsOneWidget);
    // "All" plus the new-list button are there even when empty.
    expect(find.text('All'), findsOneWidget);

    await tester.tap(find.text('Recent'));
    await tester.pump();
    expect(find.textContaining('Nothing here yet'), findsOneWidget);
  });

  testWidgets('picker: Recent lists picks newest-first', (tester) async {
    final catalog = _FakeCatalog();
    final container = _container(catalog);
    container.read(gifLibraryProvider.notifier).noteUsed(_item('r1', 'older'));
    container.read(gifLibraryProvider.notifier).noteUsed(_item('r2', 'newer'));
    await _openWith(tester, container);

    await tester.tap(find.text('Recent'));
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF newer'), findsOneWidget);
    expect(find.bySemanticsLabel('Insert GIF older'), findsOneWidget);
  });

  testWidgets('picker: a Popular result in flight cannot land on a library tab',
      (tester) async {
    final catalog = _FakeCatalog();
    final container = _container(catalog);
    container.read(gifLibraryProvider.notifier).noteUsed(_item('r1', 'recent'));
    await _openWith(tester, container);

    // Leave Popular while its request is still pending, then answer it late.
    await tester.tap(find.text('Recent'));
    await tester.pump();
    catalog.pending['|1']!.complete(_page([_item('t1', 'trending one')]));
    await tester.pump();

    expect(find.bySemanticsLabel('Insert GIF trending one'), findsNothing);
    expect(find.bySemanticsLabel('Insert GIF recent'), findsOneWidget);
  });

  testWidgets('picker: a list sorts favourites inside the Favourites tab',
      (tester) async {
    final catalog = _FakeCatalog();
    final container = _container(catalog);
    final lib = container.read(gifLibraryProvider.notifier);
    lib.toggleFavorite(_item('f1', 'in the list'));
    lib.toggleFavorite(_item('f2', 'not in the list'));
    await _openWith(tester, container);

    await tester.tap(find.text('Favourites'));
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF in the list'), findsOneWidget);
    expect(find.bySemanticsLabel('Insert GIF not in the list'), findsOneWidget);

    // Create a list inline (a dialog route would render BEHIND the picker's
    // raw OverlayEntry, so the field lives in the panel).
    await tester.tap(find.bySemanticsLabel('New favourites list'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).last, 'Reactions');
    await tester.tap(find.bySemanticsLabel('Create list'));
    await tester.pump();
    expect(find.text('Reactions'), findsOneWidget);

    // A brand-new list is empty and says so.
    expect(find.textContaining('This list is empty'), findsOneWidget);
    lib.setInCollection(
        container.read(gifLibraryProvider).collections.single.id, 'f1', true);
    await tester.pump();
    expect(find.bySemanticsLabel('Insert GIF in the list'), findsOneWidget);
    expect(find.bySemanticsLabel('Insert GIF not in the list'), findsNothing);
  });

  testWidgets('picker: failed search shows the error hint', (tester) async {
    final catalog = _FakeCatalog();
    await tester.pumpWidget(ProviderScope(
      overrides: [gifCatalogProvider.overrideWithValue(catalog)],
      child: _host(
        onOpen: (ctx) => showGifPicker(
          context: ctx,
          anchorPosition: const Offset(300, 300),
          onSelect: (_) {},
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pump();
    catalog.pending['|1']!.completeError(Exception('proxy down'));
    await tester.pump();
    expect(find.text('Search failed. Check your connection'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    // The picker plays a scale+fade exit before its overlay entry is
    // removed, so dismissal is no longer a single-frame affair.
    await tester.pump(const Duration(milliseconds: 200));
  });
}

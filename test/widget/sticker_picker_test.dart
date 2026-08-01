import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/rust/api/gifs.dart' as gifs_api;
import 'package:hollow/src/rust/api/stickers.dart' as stickers_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/chat/sticker_picker.dart';

String _h(int i) => i.toRadixString(16) * 64;

stickers_api.PersonalSticker _mine(int i, {String pack = ''}) =>
    stickers_api.PersonalSticker(
      pack: pack,
      hash: _h(i),
      name: 'mine$i',
      animated: false,
      w: 200,
      h: 200,
      source: 'upload',
    );

stickers_api.ServerSticker _server(int i) => stickers_api.ServerSticker(
      hash: _h(i),
      name: 'srv$i',
      pack: '',
      animated: false,
      w: 200,
      h: 200,
    );

/// A catalog whose network layer is faked at the RAW-FFI seam, so the real
/// cache / in-flight / timeout wrapper above it still runs (faking `page()`
/// wholesale is what hid the GIF picker's self-waiting `whenComplete`).
class _FakeCatalog extends StickerCatalog {
  final List<gifs_api.GifItem> items;
  int calls = 0;

  _FakeCatalog(this.items);

  @override
  Future<gifs_api.GifPage> fetchPage(String query, int page, String rating) async {
    calls++;
    return gifs_api.GifPage(
        items: items, page: page, hasNext: false, backoffUntil: 0);
  }

  @override
  Future<List<String>> fetchCategories() async => const [];
}

gifs_api.GifItem _remote(String id) => gifs_api.GifItem(
      id: '~$id',
      w: 200,
      h: 200,
      title: id,
      stillUrl: 'https://example.test/m/~$id.still.webp',
      smUrl: 'https://example.test/m/~$id.sm.webp',
      fullUrl: 'https://example.test/f/~$id',
    );

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<stickers_api.PersonalSticker> mine = const [],
  List<stickers_api.ServerSticker> server = const [],
  List<RecentSticker> recents = const [],
  StickerCatalog? catalog,
  String? serverId,
  void Function(String token)? onSelect,
}) async {
  final container = ProviderContainer(overrides: [
    // Bytes: every hash resolves, so cells render an Image rather than the
    // pull placeholder.
    emoteBytesProvider.overrideWith((ref, hash) async => Uint8List(0)),
    personalStickersProvider.overrideWith((ref) async => mine),
    serverStickersProvider.overrideWith((ref, id) async => server),
    if (catalog != null) stickerCatalogProvider.overrideWithValue(catalog),
    gifAutoplayProvider.overrideWith(() => _FixedBool(false)),
  ]);
  addTearDown(container.dispose);
  if (recents.isNotEmpty) {
    // The notifier is local-only state; seeding it directly is the same
    // thing loadCached() would do.
    for (final r in recents.reversed) {
      container.read(stickerRecentsProvider.notifier).noteUsed(r);
    }
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 440,
            child: StickerPickerBody(
              // Fresh mount per call: Flutter reuses an element of the same
              // type in the same slot, which would carry the previous
              // test's selected tab across a re-pump.
              key: UniqueKey(),
              serverId: serverId,
              onSelect: onSelect ?? (_) {},
            ),
          ),
        ),
      ),
    ),
  );
  // The provider overrides are async — settle so the first frame is the
  // loaded one rather than the empty placeholder.
  await tester.pumpAndSettle();
  return container;
}

class _FixedBool extends GifAutoplayNotifier {
  final bool value;
  _FixedBool(this.value);
  @override
  bool build() => value;
}

void main() {
  testWidgets('opens on Mine in a DM, on Server inside a server',
      (tester) async {
    await _pump(tester, mine: [_mine(1)]);
    expect(find.text('Server'), findsNothing,
        reason: 'no Server tab without a server');

    await _pump(tester, server: [_server(1)], serverId: 's1');
    expect(find.text('Server'), findsOneWidget);
    // The server's sticker is what shows first.
    expect(find.byType(ChatAssetImage), findsOneWidget);
  });

  testWidgets('tabs switch between the local sources', (tester) async {
    await _pump(
      tester,
      mine: [_mine(1), _mine(2)],
      server: [_server(3)],
      serverId: 's1',
    );
    expect(find.byType(ChatAssetImage), findsOneWidget); // Server

    // pumpAndSettle, not pump: personalStickersProvider is only STARTED when
    // the Mine tab first watches it, so its future resolves after this frame.
    await tester.tap(find.text('Mine'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatAssetImage), findsNWidgets(2));

    await tester.tap(find.text('Recent'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Stickers you send'), findsOneWidget);
  });

  testWidgets('picking emits a wire token and records a recent',
      (tester) async {
    String? token;
    final container = await _pump(
      tester,
      mine: [_mine(7)],
      onSelect: (t) => token = t,
    );
    await tester.tap(find.text('Mine'));
    await tester.pump();
    await tester.tap(find.byType(ChatAssetImage).first);
    await tester.pump();

    expect(token, '[a:s:${_h(7)}:200:200]');
    expect(container.read(stickerRecentsProvider).single.hash, _h(7));

    // The panel stays open — a mosaic is several stickers in one message.
    expect(find.byType(StickerPickerBody), findsOneWidget);
  });

  testWidgets('recents show newest first', (tester) async {
    final container = await _pump(tester, mine: [_mine(1), _mine(2)]);
    final notifier = container.read(stickerRecentsProvider.notifier);
    notifier.noteUsed(RecentSticker(hash: _h(1), w: 200, h: 200));
    notifier.noteUsed(RecentSticker(hash: _h(2), w: 200, h: 200));
    // Re-sending an older one moves it back to the front, not a duplicate.
    notifier.noteUsed(RecentSticker(hash: _h(1), w: 200, h: 200));
    final recents = container.read(stickerRecentsProvider);
    expect(recents.map((r) => r.hash).toList(), [_h(1), _h(2)]);
  });

  testWidgets('the KLIPY tab runs through the REAL catalog chain',
      (tester) async {
    final catalog = _FakeCatalog([_remote('a'), _remote('b')]);
    await _pump(tester, catalog: catalog);
    await tester.tap(find.text('KLIPY'));
    await tester.pumpAndSettle();

    expect(catalog.calls, 1);
    // Remote rows are network thumbnails, not asset-rail blobs.
    expect(find.byType(ChatAssetImage), findsNothing);
    expect(find.text('Powered by KLIPY'), findsOneWidget);
  });

  testWidgets('a KLIPY reply in flight can never land on a local tab',
      (tester) async {
    final catalog = _FakeCatalog([_remote('a')]);
    await _pump(tester, mine: [_mine(1)], catalog: catalog);
    await tester.tap(find.text('KLIPY'));
    await tester.pump(); // request issued, not yet settled
    await tester.tap(find.text('Mine'));
    await tester.pumpAndSettle();

    // Back on a local tab, showing the local sticker — not KLIPY results.
    expect(find.byType(ChatAssetImage), findsOneWidget);
  });

  testWidgets('pack chips filter the vault and survive an empty pack',
      (tester) async {
    await _pump(tester, mine: [
      _mine(1, pack: 'autumn'),
      _mine(2, pack: 'autumn'),
      _mine(3),
    ]);
    await tester.tap(find.text('Mine'));
    await tester.pump();
    expect(find.byType(ChatAssetImage), findsNWidgets(3));

    await tester.tap(find.text('autumn'));
    await tester.pump();
    expect(find.byType(ChatAssetImage), findsNWidgets(2));
    // The upload button names where the upload lands.
    expect(find.textContaining('autumn'), findsWidgets);

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(find.byType(ChatAssetImage), findsNWidgets(3));
  });

  testWidgets('search filters the local vault without touching the network',
      (tester) async {
    final catalog = _FakeCatalog([_remote('a')]);
    await _pump(tester,
        mine: [_mine(1), _mine(2)], catalog: catalog);
    await tester.tap(find.text('Mine'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'mine1');
    await tester.pump();

    expect(find.byType(ChatAssetImage), findsOneWidget);
    expect(catalog.calls, 0, reason: 'a local filter must not hit the proxy');
  });

  // ── Pack creation and management (issue #36) ────────────────────────

  testWidgets('a created pack gets a chip before it holds anything',
      (tester) async {
    // The whole point of declared packs: a pack is a COLUMN on the rows, so
    // an empty one has nowhere to live in the database and would vanish the
    // instant it was made.
    final container = await _pump(tester, mine: [_mine(1)]);
    await tester.tap(find.text('Mine'));
    await tester.pump();
    expect(find.text('winter'), findsNothing);

    container.read(stickerPacksProvider.notifier).declare('winter');
    await tester.pump();
    expect(find.text('winter'), findsOneWidget);

    // Selecting it shows the empty-pack hint, not "no matches".
    await tester.tap(find.text('winter'));
    await tester.pump();
    expect(find.byType(ChatAssetImage), findsNothing);
    expect(find.textContaining('This pack is empty'), findsOneWidget);
  });

  testWidgets('the All view shows a multi-pack sticker exactly once',
      (tester) async {
    // personal_stickers is keyed on (pack, hash), so one sticker in two packs
    // is two ROWS — rendering both reads as a duplicate rather than as
    // membership.
    await _pump(tester, mine: [
      _mine(1, pack: 'autumn'),
      _mine(1, pack: 'winter'),
      _mine(2),
    ]);
    await tester.tap(find.text('Mine'));
    await tester.pump();
    expect(find.byType(ChatAssetImage), findsNWidgets(2));

    // …and still appears under each pack it belongs to.
    await tester.tap(find.text('autumn'));
    await tester.pump();
    expect(find.byType(ChatAssetImage), findsOneWidget);
    await tester.tap(find.text('winter'));
    await tester.pump();
    expect(find.byType(ChatAssetImage), findsOneWidget);
  });

  testWidgets('Share to this chat only appears when there is a chat to share to',
      (tester) async {
    await _pump(tester, mine: [_mine(1, pack: 'autumn')]);
    await tester.tap(find.text('Mine'));
    await tester.pump();
    await tester.longPress(find.text('autumn'));
    await tester.pumpAndSettle();
    expect(find.text('Share to this chat'), findsNothing,
        reason: 'no onSharePack host means nowhere to send it');
    expect(find.text('Save pack to file…'), findsOneWidget);
  });

  testWidgets('Add to pack opens a second menu listing the packs it is not in',
      (tester) async {
    // Two-level menus only work because showGifMenu dismisses the first menu
    // BEFORE running the item's onTap — otherwise the second would open
    // behind a full-screen barrier that eats the next tap.
    final container = await _pump(tester, mine: [
      _mine(1, pack: 'autumn'),
      _mine(2, pack: 'winter'),
    ]);
    container.read(stickerPacksProvider.notifier).declare('spring');
    await tester.tap(find.text('Mine'));
    await tester.pump();

    await tester.longPress(find.byType(ChatAssetImage).first);
    await tester.pumpAndSettle();
    expect(find.text('Add to pack…'), findsOneWidget);

    await tester.tap(find.text('Add to pack…'));
    await tester.pumpAndSettle();

    // These exist ONLY in the menu.
    expect(find.text('Add to pack'), findsOneWidget, reason: 'menu header');
    expect(find.text('New pack…'), findsOneWidget);

    // The chip row stays visible behind the menu, so a pack the menu OFFERS
    // is found twice (chip + menu entry) and one it withholds only once.
    // 'autumn' is where this sticker already lives, so it must not be offered.
    expect(find.text('winter'), findsNWidgets(2));
    expect(find.text('spring'), findsNWidgets(2));
    expect(find.text('autumn'), findsOneWidget,
        reason: 'the pack it is already in is not offered again');
  });

  group('declared packs', () {
    test('reject a duplicate name rather than silently merging', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final packs = container.read(stickerPacksProvider.notifier);

      expect(packs.declare('autumn'), isTrue);
      expect(packs.declare('autumn'), isFalse);
      // Case-insensitive: two packs differing only in case are the same pack
      // to a human, and merging one into the other would lose the split they
      // were drawing.
      expect(packs.declare('AUTUMN'), isFalse);
      expect(packs.declare(' autumn '), isFalse);
      expect(container.read(stickerPacksProvider), ['autumn']);
    });

    test('ignore an empty name', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final packs = container.read(stickerPacksProvider.notifier);
      expect(packs.declare(''), isFalse);
      expect(packs.declare('   '), isFalse);
      expect(container.read(stickerPacksProvider), isEmpty);
    });

    test('rename and forget keep the list in step', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final packs = container.read(stickerPacksProvider.notifier);

      packs.declare('autumn');
      packs.declare('winter');
      packs.rename('autumn', 'fall');
      expect(container.read(stickerPacksProvider), ['fall', 'winter']);

      packs.forget('fall');
      expect(container.read(stickerPacksProvider), ['winter']);
    });
  });
}

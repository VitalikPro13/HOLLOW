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
}

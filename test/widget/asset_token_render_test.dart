import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';

/// A well-formed 1x1 transparent PNG (Image.memory decodes it fine — the
/// asset render path doesn't care that real assets are WebP).
final Uint8List _kTinyPng = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

final _hash = 'a' * 64;

/// Distinct hashes so a run's members are separately findable.
String _h(int i) => i.toRadixString(16) * 64;

Future<ProviderContainer> _pump(
  WidgetTester tester,
  String text,
  Map<String, Uint8List> bytesByHash, {
  AssetTiling tiling = (top: false, bottom: false),
  double width = 800,
}) async {
  final container = ProviderContainer(overrides: [
    emoteBytesProvider.overrideWith((ref, hash) async => bytesByHash[hash]),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: MessageText(text, tiling: tiling),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Size _assetSize(WidgetTester tester) =>
    tester.getSize(find.byType(ChatAssetImage));

List<Rect> _runRects(WidgetTester tester) => tester
    .widgetList<ChatAssetImage>(find.byType(ChatAssetImage))
    .map((w) => tester.getRect(find.byWidget(w)))
    .toList();

void main() {
  group('assetChatBox', () {
    test('fits a GIF into the image-attachment box (300x250)', () {
      // Landscape: width-bound.
      expect(assetChatBox('g', 480, 270),
          within(distance: 0.5, from: const Size(300, 300 * 270 / 480)));
      // Portrait: height-bound. THE bug Vitalik hit — 480 wide made a tall
      // GIF taller than the whole viewport.
      expect(assetChatBox('g', 270, 480),
          within(distance: 0.5, from: const Size(250 * 270 / 480, 250)));
    });

    test('never upscales past the source pixels', () {
      expect(assetChatBox('g', 100, 80), const Size(100, 80));
      expect(assetChatBox('s', 64, 64), const Size(64, 64));
    });

    test('stickers use their own 160px box', () {
      expect(assetChatBox('s', 512, 512), const Size(160, 160));
    });

    test('degenerate dimensions fall back to the full box', () {
      expect(fitAssetBox(0, 0, maxW: 300, maxH: 250), const Size(300, 250));
    });
  });

  testWidgets('asset token reserves its final box before bytes land',
      (tester) async {
    final bytesByHash = <String, Uint8List>{};
    final container =
        await _pump(tester, '[a:g:$_hash:480:270]', bytesByHash);

    // No bytes yet: a placeholder box (icon, no Image) already sized to the
    // final box, so nothing reflows when the pull lands.
    expect(find.byType(ChatAssetImage), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    final reserved = _assetSize(tester);
    expect(reserved,
        within(distance: 0.5, from: const Size(300, 300 * 270 / 480)));

    // Bytes arrive (the event listener invalidates the per-hash provider —
    // same flow as NetworkEvent_EmoteAssetsReceived).
    bytesByHash[_hash] = _kTinyPng;
    container.invalidate(emoteBytesProvider(_hash));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(_assetSize(tester), reserved, reason: 'zero reflow');
  });

  testWidgets('a caption never shrinks the media — same box either way',
      (tester) async {
    await _pump(tester, '[a:g:$_hash:480:270]', {});
    final alone = _assetSize(tester);

    // Text on the SAME line is a caption, not a reason to shrink the GIF to
    // two line-heights (the "massive alone / tiny with text" complaint).
    await _pump(tester, '[a:g:$_hash:480:270] Hello', {});
    expect(_assetSize(tester), alone);
    expect(find.textContaining('Hello', findRichText: true), findsOneWidget);

    // Caption before the media reads the same way.
    await _pump(tester, 'Hello [a:g:$_hash:480:270]', {});
    expect(_assetSize(tester), alone);

    // …and so does an explicit newline.
    await _pump(tester, 'first line\n[a:g:$_hash:480:270]\nlast line', {});
    expect(_assetSize(tester), alone);
  });

  testWidgets('a tall GIF is bounded by height, not stretched to 480 wide',
      (tester) async {
    await _pump(tester, '[a:g:$_hash:270:480]', {});
    final size = _assetSize(tester);
    expect(size.height, closeTo(250, 0.5));
    expect(size.width, closeTo(250 * 270 / 480, 0.5));
  });

  testWidgets('malformed asset tokens render as plain text', (tester) async {
    // Out-of-bounds dims fail the parse and stay literal text.
    final bad = '[a:g:$_hash:5000:10]';
    await _pump(tester, bad, {});
    expect(find.byType(ChatAssetImage), findsNothing);
    expect(find.textContaining('[a:g:', findRichText: true), findsOneWidget);
  });

  // ── Sticker runs (the Telegram tiling effect) ─────────────────────────

  group('sticker runs', () {
    String run(int n, {String sep = ''}) => List.generate(
        n, (i) => '[a:s:${_h(i + 1)}:200:200]').join(sep);

    testWidgets('adjacent stickers tile edge to edge with no gap',
        (tester) async {
      await _pump(tester, run(3), {});
      final rects = _runRects(tester);
      expect(rects, hasLength(3));
      // Same row, same height, and each starts exactly where the last ended.
      expect(rects[0].top, closeTo(rects[1].top, 0.01));
      expect(rects[1].top, closeTo(rects[2].top, 0.01));
      expect(rects[0].height, closeTo(rects[1].height, 0.01));
      expect(rects[1].left, closeTo(rects[0].right, 0.01));
      expect(rects[2].left, closeTo(rects[1].right, 0.01));
    });

    testWidgets('a space between stickers is not a gap', (tester) async {
      await _pump(tester, run(3, sep: '  '), {});
      final rects = _runRects(tester);
      expect(rects, hasLength(3));
      expect(rects[1].left, closeTo(rects[0].right, 0.01),
          reason: 'horizontal whitespace inside a run is absorbed');
    });

    testWidgets('a GIF never joins a run — each stays its own block',
        (tester) async {
      await _pump(
          tester, '[a:g:${_h(1)}:200:200][a:g:${_h(2)}:200:200]', {});
      final rects = _runRects(tester);
      expect(rects, hasLength(2));
      expect(rects[1].top, greaterThanOrEqualTo(rects[0].bottom),
          reason: 'GIFs stack, they do not tile');
    });

    testWidgets('a run shrinks to fit one line rather than wrapping',
        (tester) async {
      // 5 x 200px stickers want 800px at the 160 box; the pane is 420.
      await _pump(tester, run(5), {}, width: 420);
      final rects = _runRects(tester);
      expect(rects, hasLength(5));
      for (final r in rects) {
        expect(r.top, closeTo(rects.first.top, 0.01),
            reason: 'all five stay on one line');
      }
      expect(rects.last.right, lessThanOrEqualTo(420.5));
      expect(rects.first.height, lessThan(160),
          reason: 'the shared height shrank to make them fit');
    });

    testWidgets('a run too crowded to read wraps instead of shrinking',
        (tester) async {
      await _pump(tester, run(12), {}, width: 300);
      final rects = _runRects(tester);
      expect(rects, hasLength(12));
      expect(rects.any((r) => r.top > rects.first.top), isTrue,
          reason: 'wrapped to a second line rather than going microscopic');
      expect(rects.first.height, greaterThanOrEqualTo(44));
    });

    testWidgets('a single sticker still uses the plain 160 box',
        (tester) async {
      await _pump(tester, run(1), {});
      expect(_assetSize(tester), const Size(160, 160));
    });

    testWidgets('a caption still breaks the line around a run',
        (tester) async {
      await _pump(tester, '${run(2)} nice', {});
      expect(_runRects(tester), hasLength(2));
      expect(find.textContaining('nice', findRichText: true), findsOneWidget);
    });
  });

  group('cross-message tiling', () {
    testWidgets('a tiled seam removes the padding on that side',
        (tester) async {
      const token = '[a:s:'
          '0000000000000000000000000000000000000000000000000000000000000000'
          ':200:200]';
      await _pump(tester, token, {});
      final untiled = tester.getRect(find.byType(ChatAssetImage));

      await _pump(tester, token, {}, tiling: (top: true, bottom: true));
      final tiled = tester.getRect(find.byType(ChatAssetImage));

      // Same media box; it just sits 4px higher with the padding gone.
      expect(tiled.size, untiled.size);
      expect(tiled.top, lessThan(untiled.top));
    });

    test('corner rounding is outer-edges-only across a run', () {
      // The radius rule itself — a middle piece must be square on every
      // corner or the seam gets notched.
      const r = 8.0;
      final middle = stickerRunRadius(
          first: false, last: false, tileTop: false, tileBottom: false);
      expect(middle, BorderRadius.zero);

      final only = stickerRunRadius(
          first: true, last: true, tileTop: false, tileBottom: false);
      expect(only, BorderRadius.circular(r));

      // Tiling downward squares the bottom corners so the seam is invisible.
      final tilesDown = stickerRunRadius(
          first: true, last: true, tileTop: false, tileBottom: true);
      expect(tilesDown.topLeft, const Radius.circular(r));
      expect(tilesDown.bottomLeft, Radius.zero);
    });
  });

  group('isStickerOnlyMessage', () {
    test('accepts a bare run, with or without spacing', () {
      expect(isStickerOnlyMessage('[a:s:$_hash:200:200]'), isTrue);
      expect(
          isStickerOnlyMessage(
              '  [a:s:${_h(1)}:200:200] [a:s:${_h(2)}:200:200]  '),
          isTrue);
    });

    test('rejects anything that is not purely stickers', () {
      expect(isStickerOnlyMessage(''), isFalse);
      expect(isStickerOnlyMessage('hi'), isFalse);
      expect(isStickerOnlyMessage('[a:s:$_hash:200:200] hi'), isFalse);
      // A GIF is not a sticker — GIF messages must not tile.
      expect(isStickerOnlyMessage('[a:g:$_hash:200:200]'), isFalse);
      // Mixed run: the GIF disqualifies it.
      expect(
          isStickerOnlyMessage(
              '[a:s:${_h(1)}:200:200][a:g:${_h(2)}:200:200]'),
          isFalse);
    });
  });

  group('stickerTilingFor', () {
    test('tiles only where both rows qualify AND are grouped', () {
      expect(
        stickerTilingFor(
            selfIsSticker: true,
            prevIsSticker: true,
            groupedWithPrev: true,
            nextIsSticker: true,
            groupedWithNext: true),
        (prev: true, next: true),
      );
      // A group break (different author, or 5+ minutes later) ends the run.
      expect(
        stickerTilingFor(
            selfIsSticker: true,
            prevIsSticker: true,
            groupedWithPrev: false,
            nextIsSticker: true,
            groupedWithNext: true),
        (prev: false, next: true),
      );
      // A non-sticker message never tiles, whatever surrounds it.
      expect(
        stickerTilingFor(
            selfIsSticker: false,
            prevIsSticker: true,
            groupedWithPrev: true,
            nextIsSticker: true,
            groupedWithNext: true),
        (prev: false, next: false),
      );
    });
  });

  group('stickerTileCandidate', () {
    test('anything sitting in the seam disqualifies the row', () {
      bool candidate({
        bool reply = false,
        bool reactions = false,
        bool file = false,
        bool edited = false,
      }) =>
          stickerTileCandidate(
            text: '[a:s:$_hash:200:200]',
            hasReply: reply,
            hasReactions: reactions,
            hasFile: file,
            isEdited: edited,
          );
      expect(candidate(), isTrue);
      expect(candidate(reply: true), isFalse);
      expect(candidate(reactions: true), isFalse);
      expect(candidate(file: true), isFalse);
      expect(candidate(edited: true), isFalse);
    });
  });
}

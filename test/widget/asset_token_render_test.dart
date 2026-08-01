import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
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

  // ── One sticker per message (issue #36) ───────────────────────────────
  //
  // Horizontal runs are gone: nothing sent since 0.9.3 can carry more than
  // one sticker, and the pre-0.9.3 messages that can must degrade to plain
  // full-size blocks rather than shrinking to share a line.

  group('one sticker per message', () {
    String run(int n, {String sep = ''}) => List.generate(
        n, (i) => '[a:s:${_h(i + 1)}:200:200]').join(sep);

    testWidgets('a single sticker uses the plain 160 box', (tester) async {
      await _pump(tester, run(1), {});
      expect(_assetSize(tester), const Size(160, 160));
    });

    testWidgets('adjacent stickers stack at FULL size, never shrunk',
        (tester) async {
      await _pump(tester, run(3), {});
      final rects = _runRects(tester);
      expect(rects, hasLength(3));
      for (final r in rects) {
        expect(r.size, const Size(160, 160),
            reason: 'no shared height, so nothing shrinks to fit a line');
      }
      expect(rects[1].top, greaterThanOrEqualTo(rects[0].bottom));
      expect(rects[2].top, greaterThanOrEqualTo(rects[1].bottom));
    });

    testWidgets('stacked stickers do not open a blank line between them',
        (tester) async {
      await _pump(tester, run(2), {});
      final rects = _runRects(tester);
      expect(rects, hasLength(2));
      // One line break between the blocks, not two: the gap is the blocks'
      // own 4px padding, nothing more.
      expect(rects[1].top - rects[0].bottom, lessThan(20),
          reason: 'a doubled newline would leave a full empty line here');
    });

    testWidgets('a narrow pane still never shrinks a sticker', (tester) async {
      // 5 x 200px stickers wanted 800px as a run; the pane is 420. Under the
      // old shared-height rule they shrank to fit. Now they just stack.
      await _pump(tester, run(5), {}, width: 420);
      final rects = _runRects(tester);
      expect(rects, hasLength(5));
      for (final r in rects) {
        expect(r.height, 160);
      }
    });

    testWidgets('a space between stickers changes nothing', (tester) async {
      await _pump(tester, run(3, sep: '  '), {});
      final rects = _runRects(tester);
      expect(rects, hasLength(3));
      for (final r in rects) {
        expect(r.size, const Size(160, 160));
      }
    });

    testWidgets('GIFs stack the same way', (tester) async {
      await _pump(
          tester, '[a:g:${_h(1)}:200:200][a:g:${_h(2)}:200:200]', {});
      final rects = _runRects(tester);
      expect(rects, hasLength(2));
      expect(rects[1].top, greaterThanOrEqualTo(rects[0].bottom));
    });

    testWidgets('a caption still breaks the line around the sticker',
        (tester) async {
      await _pump(tester, '${run(1)} nice', {});
      expect(_assetSize(tester), const Size(160, 160));
      expect(find.textContaining('nice', findRichText: true), findsOneWidget);
    });
  });

  group('the send-side limit', () {
    test('counts every well-formed block asset, sticker or GIF', () {
      expect(countBlockAssetTokens(''), 0);
      expect(countBlockAssetTokens('hi'), 0);
      expect(countBlockAssetTokens('[a:s:${_h(1)}:200:200]'), 1);
      expect(countBlockAssetTokens('[a:s:${_h(1)}:200:200] hi'), 1);
      // GIFs share the sticker budget — they are the same visual class.
      expect(countBlockAssetTokens('[a:g:${_h(1)}:200:200]'), 1);
      // Out-of-bounds dims never parsed, so they never counted.
      expect(countBlockAssetTokens('[a:s:${_h(1)}:5000:10]'), 0);
      // Inline emotes are NOT block assets and must never be capped.
      expect(countBlockAssetTokens('[e:kappa:${_h(1)}]'), 0);
    });

    test('refuses a second asset however it was typed', () {
      final sticker = '[a:s:${_h(1)}:200:200]';
      final sticker2 = '[a:s:${_h(2)}:200:200]';
      final gif = '[a:g:${_h(3)}:200:200]';

      expect(exceedsAssetLimit(sticker), isFalse);
      expect(exceedsAssetLimit(gif), isFalse);
      expect(exceedsAssetLimit('$sticker caption'), isFalse);

      // Neither picker can produce these; a paste can.
      expect(exceedsAssetLimit('$sticker$sticker2'), isTrue);
      expect(exceedsAssetLimit('$sticker  $sticker2'), isTrue);
      expect(exceedsAssetLimit('$sticker\n$sticker2'), isTrue);
      // Stacked GIFs were the second half of the complaint.
      expect(exceedsAssetLimit('$gif$gif'), isTrue);
      // And one of each still stacks two blocks, so it is still refused.
      expect(exceedsAssetLimit('$sticker$gif'), isTrue);

      // Emotes are inline and uncapped — a message may carry many.
      expect(
          exceedsAssetLimit('$sticker [e:a:${_h(4)}] [e:b:${_h(5)}]'), isFalse);
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

      // It sits higher with the padding gone…
      expect(tiled.top, lessThan(untiled.top));
      // …and the LAYOUT box is identical. The painted rect is deliberately a
      // device pixel taller on each tiled edge (the seam bleed), so compare
      // the box the layout actually reserves, not the pixels drawn into it.
      final block = tester.widget<SizedBox>(find
          .descendant(
            of: find.byType(ChatAssetBlock),
            matching: find.byType(SizedBox),
          )
          .first);
      expect(Size(block.width!, block.height!), untiled.size);
    });

    /// Two tiled sticker messages stacked, as the panes build them.
    Future<void> pumpTiledPair(WidgetTester tester,
        {double uiScale = 1.0}) async {
      const token = '[a:s:'
          '0000000000000000000000000000000000000000000000000000000000000000'
          ':512:512]';
      final container = ProviderContainer(overrides: [
        emoteBytesProvider.overrideWith((ref, hash) async => _kTinyPng),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: UiScaleBox(
                scale: uiScale,
                child: const SizedBox(
                  width: 800,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MessageText(token, tiling: (top: false, bottom: true)),
                      MessageText(token, tiling: (top: true, bottom: false)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('the tiled seam is never a gap — the media OVERLAPS',
        (tester) async {
      // Two things were wrong. The paragraph put a ~5px line box around a
      // 160px sticker (fixed by skipping Text.rich); then, even touching
      // exactly, the two antialiased clip edges composited to `1-αβ` and let
      // the background through at some zooms and not others. The media now
      // overruns its layout box by a device pixel on a tiled edge.
      await pumpTiledPair(tester);

      final rects = _runRects(tester);
      expect(rects, hasLength(2));
      expect(rects[1].top, lessThan(rects[0].bottom),
          reason: 'exactly touching is not enough — they must overlap');

      // The LAYOUT box must be untouched, or every row below would shift.
      final layout = tester
          .widgetList<SizedBox>(find.descendant(
            of: find.byType(ChatAssetBlock).first,
            matching: find.byType(SizedBox),
          ))
          .first;
      expect(layout.height, 160.0);
      expect(layout.width, 160.0);
    });

    testWidgets('the overlap survives every interface zoom', (tester) async {
      // The bug report's exact symptom: fine at 100%, a line at 105%, smaller
      // at 110%, gone at 115%, back at 125%. Whatever the zoom, the two
      // stickers must never merely abut.
      for (final scale in const [1.0, 1.05, 1.10, 1.15, 1.20, 1.25, 1.5]) {
        await pumpTiledPair(tester, uiScale: scale);
        final rects = _runRects(tester);
        expect(rects, hasLength(2), reason: 'at ${scale}x');
        expect(rects[1].top, lessThan(rects[0].bottom),
            reason: 'a seam reopened at ${scale}x');
      }
    });

    testWidgets('an UNtiled sticker is never stretched', (tester) async {
      // The bleed is only for a seam; a lone sticker must stay pixel-exact.
      await _pump(tester, '[a:s:$_hash:512:512]', {});
      expect(_assetSize(tester), const Size(160, 160));
    });

    testWidgets('a captioned sticker still goes through the paragraph',
        (tester) async {
      // The fast path must not swallow real text.
      await _pump(tester, '[a:s:$_hash:200:200] look', {});
      expect(find.byType(ChatAssetImage), findsOneWidget);
      expect(find.textContaining('look', findRichText: true), findsOneWidget);
    });

    test('corner rounding squares only the tiled seams', () {
      // The radius rule itself — a sticker in the MIDDLE of a vertical run
      // must be square top and bottom or the seams get notched.
      const r = 8.0;
      final untiled = stickerRunRadius(tileTop: false, tileBottom: false);
      expect(untiled, BorderRadius.circular(r));

      final middle = stickerRunRadius(tileTop: true, tileBottom: true);
      expect(middle, BorderRadius.zero);

      // Tiling downward squares the bottom corners so the seam is invisible.
      final tilesDown = stickerRunRadius(tileTop: false, tileBottom: true);
      expect(tilesDown.topLeft, const Radius.circular(r));
      expect(tilesDown.topRight, const Radius.circular(r));
      expect(tilesDown.bottomLeft, Radius.zero);
      expect(tilesDown.bottomRight, Radius.zero);
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

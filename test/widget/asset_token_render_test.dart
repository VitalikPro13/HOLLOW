import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
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

Future<ProviderContainer> _pump(
  WidgetTester tester,
  String text,
  Map<String, Uint8List> bytesByHash,
) async {
  final container = ProviderContainer(overrides: [
    emoteBytesProvider.overrideWith((ref, hash) async => bytesByHash[hash]),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: MessageText(text)),
      ),
    ),
  );
  await tester.pump();
  return container;
}

Size _assetSize(WidgetTester tester) =>
    tester.getSize(find.byType(ChatAssetImage));

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
}

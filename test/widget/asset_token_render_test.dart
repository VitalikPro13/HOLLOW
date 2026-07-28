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

void main() {
  testWidgets('asset token renders a sized placeholder, then the image when '
      'bytes land', (tester) async {
    final bytesByHash = <String, Uint8List>{};
    final container =
        await _pump(tester, '[a:g:$_hash:480:270]', bytesByHash);

    // No bytes yet: a placeholder box (icon, no Image) that already
    // reserves the token's aspect ratio, so nothing reflows later.
    expect(find.byType(ChatAssetImage), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    final ratioFinder = find.byType(AspectRatio);
    expect(ratioFinder, findsOneWidget);
    expect(tester.widget<AspectRatio>(ratioFinder).aspectRatio,
        closeTo(480 / 270, 0.001));

    // Bytes arrive (the event listener invalidates the per-hash provider —
    // same flow as NetworkEvent_EmoteAssetsReceived).
    bytesByHash[_hash] = _kTinyPng;
    container.invalidate(emoteBytesProvider(_hash));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    // Still the same reserved box.
    expect(tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio,
        closeTo(480 / 270, 0.001));
  });

  testWidgets('asset token inline with text stays line-capped, block when '
      'alone on its line', (tester) async {
    // Inline: no AspectRatio (fixed SizedBox capped to the line height).
    await _pump(tester, 'look at [a:s:$_hash:512:512] this', {});
    expect(find.byType(ChatAssetImage), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);

    // Alone on its own line inside a longer message: block render.
    await _pump(tester, 'first line\n[a:s:$_hash:512:512]\nlast line', {});
    expect(find.byType(AspectRatio), findsOneWidget);
  });

  testWidgets('malformed asset tokens render as plain text', (tester) async {
    // Out-of-bounds dims fail the parse and stay literal text.
    final bad = '[a:g:$_hash:5000:10]';
    await _pump(tester, bad, {});
    expect(find.byType(ChatAssetImage), findsNothing);
    expect(find.textContaining('[a:g:', findRichText: true), findsOneWidget);
  });
}

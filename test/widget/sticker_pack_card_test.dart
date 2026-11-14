import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/stickers.dart' as stickers_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/sticker_pack_card.dart';

import '../helpers/test_app.dart';

Widget _card(String path, {Key? key}) => ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: StickerPackCard(
              key: key, diskPath: path, fileName: 'bomb.hollow-pack'),
        ),
      ),
    );

void main() {
  group('isStickerPackFile', () {
    test('claims only the pack extension', () {
      expect(isStickerPackFile('autumn.hollow-pack'), isTrue);
      expect(isStickerPackFile('my stickers.hollow-pack'), isTrue);
      // Case is the OS's business, not ours — Windows will happily hand back
      // a capitalised name for a file we wrote in lower case.
      expect(isStickerPackFile('Autumn.HOLLOW-PACK'), isTrue);
    });

    test('does not claim the other hollow containers', () {
      // These have their own import paths; grabbing one here would render an
      // "Add to my stickers" button over an archive.
      expect(isStickerPackFile('chat.hollow-archive'), isFalse);
      expect(isStickerPackFile('server.hollow-shards'), isFalse);
      expect(isStickerPackFile('backup.hollow'), isFalse);
    });

    test('does not claim a mere substring', () {
      expect(isStickerPackFile('hollow-pack'), isFalse);
      expect(isStickerPackFile('hollow-pack.zip'), isFalse);
      expect(isStickerPackFile('notes about hollow-packs.txt'), isFalse);
      expect(isStickerPackFile(''), isFalse);
    });
  });

  group('reading a received pack', () {
    late int reads;
    setUp(() {
      reads = 0;
      forgetStickerPackPreviews();
    });
    tearDown(() {
      forgetStickerPackPreviews();
      stickerPackPreviewer =
          (path) => stickers_api.previewStickerPack(path: path);
    });

    testWidgets('a pack that cannot be read shows a calm state and is read once',
        (tester) async {
      stickerPackPreviewer = (path) async {
        reads++;
        throw 'The pack manifest is too large to be real';
      };
      await tester.pumpWidget(_card('/p/bomb.hollow-pack'));
      await tester.pump();

      final note = find.text("Can't open this pack");
      expect(note, findsOneWidget);
      expect(tester.widget<Text>(note).style?.color,
          HollowTheme.of(tester.element(note)).textSecondary);
      expect(find.text('Add to my stickers'), findsNothing);

      // Rebuilds, and a fresh card for the same file (the conversation opened
      // again), never read it again.
      for (var i = 0; i < 5; i++) {
        await tester.pumpWidget(_card('/p/bomb.hollow-pack', key: ValueKey(i)));
        await tester.pump();
      }
      expect(find.text("Can't open this pack"), findsOneWidget);
      expect(reads, 1);
    });

    testWidgets('a failure that is not the file is read again on the next open',
        (tester) async {
      stickerPackPreviewer = (path) async {
        reads++;
        throw 'File key missing';
      };
      await tester.pumpWidget(_card('/p/later.hollow-pack'));
      await tester.pump();
      expect(find.text("Can't open this pack"), findsOneWidget);
      // Rebuilds of the same card never read again.
      await tester.pumpWidget(_card('/p/later.hollow-pack'));
      await tester.pump();
      expect(reads, 1);
      await tester.pumpWidget(_card('/p/later.hollow-pack', key: const ValueKey('reopened')));
      await tester.pump();
      expect(reads, 2);
    });

    testWidgets('packs are read one at a time', (tester) async {
      final pending = <Completer<stickers_api.StickerPackPreview>>[];
      stickerPackPreviewer = (path) {
        reads++;
        final done = Completer<stickers_api.StickerPackPreview>();
        pending.add(done);
        return done.future;
      };
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(
            body: Column(children: [
              StickerPackCard(diskPath: '/p/a.hollow-pack', fileName: 'a.hollow-pack'),
              StickerPackCard(diskPath: '/p/b.hollow-pack', fileName: 'b.hollow-pack'),
            ]),
          ),
        ),
      ));
      await tester.pump();
      expect(reads, 1, reason: 'the second pack was read while the first still was');
      pending.first.complete(const stickers_api.StickerPackPreview(
          pack: 'A', author: '', authorVerified: false, count: 1));
      await tester.pump();
      await tester.pump();
      expect(reads, 2);
      pending.last.complete(const stickers_api.StickerPackPreview(
          pack: 'B', author: '', authorVerified: false, count: 2));
      await tester.pump();
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('a readable pack shows its name and count', (tester) async {
      stickerPackPreviewer = (path) async {
        reads++;
        return const stickers_api.StickerPackPreview(
            pack: 'Autumn', author: '', authorVerified: false, count: 3);
      };
      await tester.pumpWidget(_card('/p/autumn.hollow-pack'));
      await tester.pump();
      expect(find.text('Autumn'), findsOneWidget);
      expect(find.text('3 stickers'), findsOneWidget);
      expect(find.text('Add to my stickers'), findsOneWidget);
      await tester.pumpWidget(_card('/p/autumn.hollow-pack', key: const ValueKey('again')));
      await tester.pump();
      expect(reads, 1);
    });
  });
}

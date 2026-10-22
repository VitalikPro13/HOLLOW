/// AR-28: an image Rust's pure decode refused never reaches Flutter's decoder,
/// and every surface says so honestly instead of looking like "still loading".
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/chat/file_attachment_widget.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';

import '../helpers/test_app.dart';

const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('hollow_refused'));
  tearDown(() {
    AtRest.debugRead = null;
    AtRest.debugReadImage = null;
    debugClearAttachmentImageCache();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget host(Widget child, {List<Override> extra = const []}) => ProviderScope(
        overrides: hollowTestOverrides(extra: extra),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('a downloaded image Rust refused shows "Can\'t show this image"',
      (tester) async {
    final path = '${tmp.path}${Platform.pathSeparator}photo.webp';
    File(path).writeAsBytesSync(const [0x48, 0x46, 0x45, 0x31]);
    AtRest.debugReadImage =
        (_) async => throw Exception("Hollow can't show this image");

    await tester.runAsync(() async {
      await tester.pumpWidget(host(FileAttachmentWidget(
        attachment: FileAttachment(
          fileId: 'f1',
          fileName: 'photo.webp',
          fileExt: 'webp',
          mimeType: 'image/webp',
          sizeBytes: 4,
          isImage: true,
          width: 400,
          height: 300,
          totalChunks: 0,
          isComplete: true,
          diskPath: path,
        ),
      )));
      for (var i = 0; i < 25 && find.byType(CantShowImage).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });

    expect(find.text("Can't show this image"), findsOneWidget);
  });

  test('an image Rust is still checking is asked for again, not refused', () async {
    AtRest.debugImageRetryDelay = Duration.zero;
    var asks = 0;
    AtRest.debugReadImage = (_) async {
      asks++;
      if (asks < 3) throw Exception(kImageNotYet);
      return Uint8List.fromList([1, 2, 3]);
    };
    expect(await AtRest.readImage('x.png'), [1, 2, 3]);
    expect(asks, 3);

    AtRest.debugReadImage = (_) async => throw Exception("Hollow can't show this image");
    await expectLater(AtRest.readImage('y.png'), throwsException);
    AtRest.debugImageRetryDelay = const Duration(seconds: 1);
  });

  testWidgets('a photo Rust would not send says why on the sender\'s row',
      (tester) async {
    const why = "Hollow can't send this image because it is too large or damaged.";
    final path = '${tmp.path}${Platform.pathSeparator}local.webp';
    File(path).writeAsBytesSync(const [1, 2, 3]);
    AtRest.debugReadImage = (_) async => Uint8List.fromList([1, 2, 3]);
    await tester.pumpWidget(host(
      FileAttachmentWidget(attachment: FileAttachment(
        fileId: 'f2',
        fileName: 'local.webp',
        fileExt: 'webp',
        mimeType: 'image/webp',
        sizeBytes: 3,
        isImage: true,
        width: 400,
        height: 300,
        totalChunks: 0,
        isComplete: true,
        diskPath: path,
      )),
      extra: [
        fileTransferProvider.overrideWith(() => _SeededTransfers({
              'f2': const FileTransferState(
                  fileId: 'f2', fileName: 'local.webp', sizeBytes: 3, totalChunks: 0, error: why),
            })),
      ],
    ));
    await tester.pump();
    expect(find.text(why), findsOneWidget);
  });

  testWidgets('a refused emote falls back to its name', (tester) async {
    await tester.pumpWidget(host(
      const EmoteImage(name: 'pog', hash: _hash, size: 24),
      extra: [
        emoteBytesProvider.overrideWith((ref, hash) async => Uint8List(0)),
      ],
    ));
    await tester.pump();
    expect(find.text(':pog:'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a refused sticker says it cannot be shown, not that it loads',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(
      const ChatAssetImage(kind: 's', hash: _hash, aspect: 1, height: 80, width: 80),
      extra: [
        emoteBytesProvider.overrideWith((ref, hash) async => Uint8List(0)),
      ],
    ));
    await tester.pump();
    expect(find.bySemanticsLabel("Can't show this sticker"), findsOneWidget);
    expect(find.bySemanticsLabel('sticker loading'), findsNothing);
    expect(find.byType(Image), findsNothing);
    handle.dispose();
  });
}

class _SeededTransfers extends FileTransferNotifier {
  final Map<String, FileTransferState> seed;
  _SeededTransfers(this.seed);

  @override
  Map<String, FileTransferState> build() => seed;
}

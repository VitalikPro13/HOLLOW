/// An attachment on disk is ciphertext, so nothing paints it with dart:io any
/// more: [AttachmentImage] is the one surface, and it must route a still
/// through Flutter's image cache and an animation through the frame decoder.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';

/// 1x1 transparent PNG.
final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// 1x1 GIF.
final Uint8List _gif = base64Decode(
    'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');

void main() {
  late Directory tmp;
  late List<String> reads;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hollow_attachment_image');
    reads = <String>[];
    debugClearAttachmentImageCache();
  });

  tearDown(() {
    AtRest.debugRead = null;
    debugClearAttachmentImageCache();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A file whose CONTENT is irrelevant: on disk it is ciphertext, and the
  /// mocked read is what hands the widget real pixels.
  String ciphertextAt(String name) {
    final path = '${tmp.path}${Platform.pathSeparator}$name';
    File(path).writeAsBytesSync(<int>[0x48, 0x46, 0x45, 0x31, 0x01, 0x00]);
    return path;
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
  }

  testWidgets('a still reads through AtRest, not the file on disk',
      (tester) async {
    final path = ciphertextAt('shot.png');
    AtRest.debugRead = (p) async {
      reads.add(p);
      return _png;
    };

    await pump(tester, AttachmentImage(path: path, width: 32, height: 32));
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AtRestImageProvider>());
    expect((image.image as AtRestImageProvider).path, path);
  });

  test('the cache key tracks the file on disk', () async {
    final path = ciphertextAt('shot.png');
    final provider = AtRestImageProvider(path);
    final first = await provider.obtainKey(ImageConfiguration.empty);
    expect(first.path, path);
    expect(first.length, 6);

    File(path).writeAsBytesSync(List<int>.filled(64, 7));
    final second = await provider.obtainKey(ImageConfiguration.empty);
    expect(second, isNot(equals(first)));
    expect(second.length, 64);
  });

  testWidgets('the provider decrypts before it decodes', (tester) async {
    final path = ciphertextAt('shot.png');
    AtRest.debugRead = (p) async {
      reads.add(p);
      return _png;
    };

    await tester.runAsync(() async {
      final done = Completer<ImageInfo>();
      AtRestImageProvider(path).resolve(ImageConfiguration.empty).addListener(
            ImageStreamListener((info, _) => done.complete(info),
                onError: (Object e, _) => done.completeError(e)),
          );
      final info = await done.future.timeout(const Duration(seconds: 10));
      expect(info.image.width, 1);
      info.dispose();
    });

    expect(reads, [path]);
  });

  testWidgets('an animation is handed decrypted bytes, never a path',
      (tester) async {
    final path = ciphertextAt('wave.gif');
    AtRest.debugRead = (p) async {
      reads.add(p);
      return _gif;
    };

    await pump(
        tester,
        AttachmentImage(
            path: path, animated: true, width: 32, height: 32));
    await tester.pump();

    expect(reads, [path]);
    final gif = tester.widget<AnimatedGifImage>(find.byType(AnimatedGifImage));
    expect(gif.bytes, _gif);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a second animated mount reuses the cached bytes',
      (tester) async {
    final path = ciphertextAt('wave.gif');
    AtRest.debugRead = (p) async {
      reads.add(p);
      return _gif;
    };

    await pump(tester, AttachmentImage(path: path, animated: true));
    await tester.pump();
    await pump(tester, const SizedBox.shrink());
    await pump(tester, AttachmentImage(path: path, animated: true));
    await tester.pump();

    expect(reads, hasLength(1));
  });

  testWidgets('a failed read shows the error widget, not an exception',
      (tester) async {
    final path = ciphertextAt('gone.gif');
    AtRest.debugRead = (_) async => throw const FileSystemException('no key');

    await pump(
        tester,
        AttachmentImage(
          path: path,
          animated: true,
          errorWidget: const Text('broken'),
        ));
    await tester.pump();

    expect(find.text('broken'), findsOneWidget);
  });
}

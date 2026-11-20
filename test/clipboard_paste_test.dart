/// #142: what a paste takes from the clipboard. The formats are what each
/// source puts there (ShareX's are from its source, WindowsClipboard.SetImage
/// and CopyFile); nothing here touches a real clipboard.
library;


import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/chat/clipboard_paste.dart';
import 'package:super_clipboard/super_clipboard.dart';

void main() {
  PastedPathKind kindOf(String p) => p.contains('missing')
      ? PastedPathKind.missing
      : p.endsWith('folder')
          ? PastedPathKind.folder
          : PastedPathKind.file;

  PastePlan plan(
          {List<String> files = const [],
          List<SimpleFileFormat> images = const []}) =>
      planPaste(filePaths: files, kindOf: kindOf, imageFormats: images);

  test('ShareX "Copy image": its PNG, not the white-filled DIB', () {
    // CF_DIB plus a registered "PNG"; the plugin offers the DIB as PNG too.
    final p = plan(images: [Formats.png]);
    expect(p, isA<PasteImage>());
    expect((p as PasteImage).format, Formats.png);
  });

  test('a bare DIB (Paint) is read as the PNG the plugin makes of it', () {
    final p = plan(images: [Formats.bmp, Formats.png]);
    expect((p as PasteImage).format, Formats.png);
  });

  test('ShareX "Copy file": a recording is staged as the file itself', () {
    // CF_HDROP alone; before #142 only image types were read from it.
    final p = plan(files: [r'C:\Users\a\Documents\ShareX\Screenshots\clip.mp4']);
    expect(p, isA<PasteFiles>());
    expect((p as PasteFiles).files.single,
        (path: r'C:\Users\a\Documents\ShareX\Screenshots\clip.mp4', name: 'clip.mp4'));
  });

  test('a copied screenshot file keeps its own name', () {
    final p = plan(
        files: [r'C:\shots\Discord_2026-11-20.png'], images: [Formats.png]);
    expect((p as PasteFiles).files.single.name, 'Discord_2026-11-20.png');
  });

  test('several copied files are all staged, in order', () {
    final p = plan(files: ['/home/a/one.txt', '/home/a/two.zip', '/home/a/3.webp']);
    expect([for (final f in (p as PasteFiles).files) f.name],
        ['one.txt', 'two.zip', '3.webp']);
  });

  test('a file and its preview bytes (Finder offers the icon) give the file',
      () {
    final p = plan(files: ['/Users/a/Desktop/photo.heic'], images: [Formats.tiff]);
    expect((p as PasteFiles).files.single.name, 'photo.heic');
  });

  // UI review, Nov 20: a copied folder pasted its Finder icon as a TIFF.
  test('a copied folder never pastes the icon beside it', () {
    final p = plan(files: ['/Users/a/Desktop/folder'], images: [Formats.tiff]);
    expect(p, isA<PasteOnlyFolders>());
    expect(pasteNotice(p), "Folders can't be sent");
  });

  test('files copied with a folder are staged, and the folder is named', () {
    final p = plan(
        files: ['/Users/a/one.png', '/Users/a/folder', '/Users/a/two.mp4'],
        images: [Formats.tiff]);
    expect([for (final f in (p as PasteFiles).files) f.name],
        ['one.png', 'two.mp4']);
    expect(p.skippedFolders, 1);
    expect(pasteNotice(p), "Folders can't be sent, so the folder was left out");
    expect(
        pasteNotice(plan(files: ['/a/x.txt', '/a/folder', '/b/folder'])),
        "Folders can't be sent, so 2 folders were left out");
  });

  test('copied files that are gone paste nothing, not their preview', () {
    final p = plan(files: [r'C:\shots\missing.png'], images: [Formats.jpeg]);
    expect(p, isA<PasteGone>());
    expect(pasteNotice(p), isNull);
  });

  test('a clipboard with neither is nothing to paste', () {
    expect(plan(), isA<PasteNothing>());
    expect(pasteNotice(plan()), isNull);
  });

  test('every image format on offer has its own extension', () {
    expect([for (final f in kPasteImageFormats) extensionForPasteFormat(f)],
        ['png', 'jpg', 'gif', 'webp', 'bmp', 'tiff']);
  });

  group('one clipboard read', () {
    late List<List<PastedFile>> staged;
    late List<String> texts, notices;
    late Map<String, Uint8List> written;
    final reader = clipboardOfferReader;
    final kind = pastedPathKind;
    final size = pastedFileSize;
    final writer = pastedImageWriter;
    tearDown(() {
      clipboardOfferReader = reader;
      pastedPathKind = kind;
      pastedFileSize = size;
      pastedImageWriter = writer;
    });

    setUp(() {
      staged = [];
      texts = [];
      notices = [];
      written = {};
      pastedPathKind = (p) async => kindOf(p);
      pastedFileSize = (p) async => p.length;
      pastedImageWriter = (name, bytes) async {
        written[name] = bytes;
        return '/data/temp/$name';
      };
    });

    Future<void> paste(ClipboardOffer offer) {
      clipboardOfferReader = () async => offer;
      return pasteFromSystemClipboard(
          onFiles: staged.add, onText: texts.add, onNotice: notices.add);
    }

    ClipboardOffer offer(
            {List<String> files = const [],
            List<SimpleFileFormat> images = const [],
            String? text}) =>
        ClipboardOffer(
          filePaths: files,
          imageFormats: images,
          readImage: (_) async => Uint8List.fromList([1, 2, 3]),
          readText: () async => text,
        );

    // UI review, Nov 20: Finder puts the file name, Nautilus the path, in the
    // text beside a copied file.
    test('copied files are the whole paste, never their names as text',
        () async {
      await paste(offer(
          files: ['/home/a/photo.png'],
          images: [Formats.png],
          text: '/home/a/photo.png'));
      expect(staged.single.single,
          (path: '/home/a/photo.png', name: 'photo.png', size: 17));
      expect(texts, isEmpty);
      expect(written, isEmpty, reason: 'no image bytes read');
    });

    test('an image is sealed under the data root and its text still lands',
        () async {
      await paste(offer(images: [Formats.png], text: 'look'));
      expect(written.keys.single, startsWith('clipboard_'));
      expect(written.keys.single, endsWith('.png'));
      expect(staged.single.single.size, 3);
      expect(staged.single.single.path, '/data/temp/${written.keys.single}');
      expect(texts, ['look']);
    });

    test('text alone is pasted as text', () async {
      await paste(offer(text: 'hello'));
      expect(texts, ['hello']);
      expect(staged, isEmpty);
    });

    test('a copied folder stages nothing and says why', () async {
      await paste(offer(
          files: ['/Users/a/folder'], images: [Formats.tiff], text: 'folder'));
      expect(staged, isEmpty);
      expect(texts, isEmpty);
      expect(notices, ["Folders can't be sent"]);
    });

    test('a read that fails pastes nothing it cannot see', () async {
      clipboardOfferReader = () async => throw StateError('no clipboard');
      await expectLater(
          pasteFromSystemClipboard(onFiles: staged.add), completes);
      expect(staged, isEmpty);
    });
  });

  test('a clipboard read that stalls gives up', () async {
    final bytes = await readClipboardFile(_StalledReader(), Formats.png,
        timeout: const Duration(milliseconds: 50));
    expect(bytes, isNull);
  });
}

/// A reader whose file read starts and never finishes.
class _StalledReader implements ClipboardReader {
  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) =>
      _Progress();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Progress implements ReadProgress {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

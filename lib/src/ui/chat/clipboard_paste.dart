import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show Clipboard;
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:super_clipboard/super_clipboard.dart';

/// A file a paste stages: where it is, the name it is sent under, its size.
typedef PastedFile = ({String path, String name, int size});

/// Image bytes a paste reads, best first. On Windows a bare CF_DIB/CF_DIBV5
/// (Paint, ShareX's copy without its PNG) is offered as PNG by the plugin.
const List<SimpleFileFormat> kPasteImageFormats = [
  Formats.png,
  Formats.jpeg,
  Formats.gif,
  Formats.webp,
  Formats.bmp,
  Formats.tiff,
];

/// What a listed path is on disk, for [planPaste].
enum PastedPathKind { file, folder, missing }

/// What a paste does with what the clipboard offers.
sealed class PastePlan {
  const PastePlan();
}

/// Stage these files as they are, under their own names; [skippedFolders]
/// folders copied with them are left out.
final class PasteFiles extends PastePlan {
  final List<({String path, String name})> files;
  final int skippedFolders;
  const PasteFiles(this.files, {this.skippedFolders = 0});
}

/// Only folders were copied, and a folder is not a file to send.
final class PasteOnlyFolders extends PastePlan {
  const PasteOnlyFolders();
}

/// Read the image bytes in [format] into a new file.
final class PasteImage extends PastePlan {
  final SimpleFileFormat format;
  const PasteImage(this.format);
}

/// No file and no image: the text, if any, is the paste.
final class PasteNothing extends PastePlan {
  const PasteNothing();
}

/// Copied files that are no longer there: nothing is staged, and the text
/// beside them (their names) is not the paste either.
final class PasteGone extends PastePlan {
  const PasteGone();
}

/// Decides a paste (#142). Copied files (Explorer, ShareX "Copy file to
/// clipboard", Finder, Nautilus) win over everything else on offer: they are
/// the real file under its own name, of any type. Once any file is listed, the
/// image bytes and text beside it only describe it and are never the paste
/// (Finder offers the file's or folder's ICON, Nautilus its path as text).
/// [kindOf] says what each of [filePaths] is on disk. With no file listed, the
/// first of [kPasteImageFormats] in [imageFormats] is read.
PastePlan planPaste({
  required List<String> filePaths,
  required PastedPathKind Function(String path) kindOf,
  required List<SimpleFileFormat> imageFormats,
}) {
  if (filePaths.isNotEmpty) {
    final files = <({String path, String name})>[];
    var folders = 0;
    for (final path in filePaths) {
      switch (kindOf(path)) {
        case PastedPathKind.file:
          files.add((path: path, name: _baseName(path)));
        case PastedPathKind.folder:
          folders++;
        case PastedPathKind.missing:
          break;
      }
    }
    if (files.isNotEmpty) return PasteFiles(files, skippedFolders: folders);
    return folders > 0 ? const PasteOnlyFolders() : const PasteGone();
  }
  for (final format in kPasteImageFormats) {
    if (imageFormats.contains(format)) return PasteImage(format);
  }
  return const PasteNothing();
}

String _baseName(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  return parts.lastWhere((p) => p.isNotEmpty, orElse: () => path);
}

/// The toast a paste shows, or null: a copied folder is left out, and a copy
/// of folders alone stages nothing.
String? pasteNotice(PastePlan plan) => switch (plan) {
      PasteOnlyFolders() => "Folders can't be sent",
      PasteFiles(skippedFolders: 1) =>
        "Folders can't be sent, so the folder was left out",
      PasteFiles(:final skippedFolders) when skippedFolders > 1 =>
        "Folders can't be sent, so $skippedFolders folders were left out",
      _ => null,
    };

/// One read of the clipboard: the paths of the files it lists, the image
/// formats it offers, and how to read an image or the text.
class ClipboardOffer {
  final List<String> filePaths;
  final List<SimpleFileFormat> imageFormats;
  final Future<Uint8List?> Function(SimpleFileFormat format) readImage;
  final Future<String?> Function() readText;

  const ClipboardOffer({
    this.filePaths = const [],
    this.imageFormats = const [],
    required this.readImage,
    required this.readText,
  });
}

/// The clipboard read; tests swap it.
@visibleForTesting
Future<ClipboardOffer?> Function() clipboardOfferReader = _readSystemOffer;

/// What a listed path is on disk; tests swap it.
@visibleForTesting
Future<PastedPathKind> Function(String path) pastedPathKind = _kindOnDisk;

/// The size of a staged file; tests swap it.
@visibleForTesting
Future<int> Function(String path) pastedFileSize =
    (path) => File(path).length();

/// Writes pasted image bytes into the data root's temp; tests swap it.
/// Sealed at rest like every file under the data root, and that folder is
/// emptied by every launch and by a wipe.
@visibleForTesting
Future<String> Function(String name, Uint8List bytes) pastedImageWriter =
    _writeToDataRootTemp;

Future<String> _writeToDataRootTemp(String name, Uint8List bytes) async {
  final sep = Platform.pathSeparator;
  final dir = '$hollowDataDir${sep}temp';
  await Directory(dir).create(recursive: true);
  final path = '$dir$sep$name';
  await AtRest.write(path, bytes);
  return path;
}

/// Pastes what the clipboard holds: copied files to [onFiles] as they are,
/// else an image (saved under the data root) to [onFiles] and the text to
/// [onText]. [onNotice] hears what was left out. [onText] is null where the
/// text already landed (the Windows read during the key event).
Future<void> pasteFromSystemClipboard({
  required void Function(List<PastedFile> files) onFiles,
  void Function(String text)? onText,
  void Function(String notice)? onNotice,
}) async {
  ClipboardOffer? offer;
  try {
    offer = await clipboardOfferReader();
  } catch (_) {
    offer = null;
  }
  if (offer == null) {
    // No file reader here: the text is still a paste.
    if (onText != null) {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      if (text != null && text.isNotEmpty) onText(text);
    }
    return;
  }
  final kinds = <String, PastedPathKind>{
    for (final path in offer.filePaths) path: await _safeKind(path),
  };
  final plan = planPaste(
    filePaths: offer.filePaths,
    kindOf: (p) => kinds[p] ?? PastedPathKind.missing,
    imageFormats: offer.imageFormats,
  );
  final notice = pasteNotice(plan);
  if (notice != null) onNotice?.call(notice);
  switch (plan) {
    case PasteFiles(:final files):
      onFiles([
        for (final f in files)
          (path: f.path, name: f.name, size: await _safeSize(f.path)),
      ]);
    case PasteImage():
      await _pasteText(offer, onText);
      // A format that turns out empty gives way to the next one on offer.
      for (final format
          in kPasteImageFormats.skipWhile((f) => f != plan.format)) {
        if (!offer.imageFormats.contains(format)) continue;
        final file = await _saveImage(offer, format);
        if (file != null) {
          onFiles([file]);
          return;
        }
      }
    case PasteNothing():
      await _pasteText(offer, onText);
    case PasteOnlyFolders() || PasteGone():
      return;
  }
}

Future<void> _pasteText(
    ClipboardOffer offer, void Function(String text)? onText) async {
  if (onText == null) return;
  String? text;
  try {
    text = await offer.readText();
  } catch (_) {
    text = null;
  }
  if (text != null && text.isNotEmpty) onText(text);
}

Future<PastedPathKind> _safeKind(String path) async {
  try {
    return await pastedPathKind(path);
  } catch (_) {
    return PastedPathKind.missing;
  }
}

Future<int> _safeSize(String path) async {
  try {
    return await pastedFileSize(path);
  } catch (_) {
    return 0;
  }
}

Future<PastedPathKind> _kindOnDisk(String path) async =>
    switch (await FileSystemEntity.type(path)) {
      FileSystemEntityType.file => PastedPathKind.file,
      FileSystemEntityType.directory => PastedPathKind.folder,
      _ => PastedPathKind.missing,
    };

Future<ClipboardOffer?> _readSystemOffer() async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) return null;
  final reader = await clipboard.read();
  final paths = <String>[];
  for (final item in reader.items) {
    if (!item.canProvide(Formats.fileUri)) continue;
    try {
      final uri = await item.readValue(Formats.fileUri);
      if (uri != null && uri.isScheme('file')) paths.add(uri.toFilePath());
    } catch (_) {
      // An entry the plugin cannot read as a path is not a file to stage.
    }
  }
  return ClipboardOffer(
    filePaths: paths,
    imageFormats: [
      for (final f in kPasteImageFormats)
        if (reader.canProvide(f)) f,
    ],
    readImage: (format) => readClipboardFile(reader, format),
    readText: () async =>
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
  );
}

Future<PastedFile?> _saveImage(
    ClipboardOffer offer, SimpleFileFormat format) async {
  final bytes = await offer.readImage(format);
  if (bytes == null || bytes.isEmpty) return null;
  final name = 'clipboard_${DateTime.now().millisecondsSinceEpoch}'
      '.${extensionForPasteFormat(format)}';
  try {
    final path = await pastedImageWriter(name, bytes);
    return (path: path, name: name, size: bytes.length);
  } catch (_) {
    return null;
  }
}

/// How long a clipboard file read may take before the paste gives up on it.
const Duration kClipboardReadTimeout = Duration(seconds: 15);

/// The bytes of [format]; null when the clipboard gives none, the read cannot
/// start, or it takes longer than [timeout].
@visibleForTesting
Future<Uint8List?> readClipboardFile(
    ClipboardReader reader, SimpleFileFormat format,
    {Duration timeout = kClipboardReadTimeout}) {
  final completer = Completer<Uint8List?>();
  final progress = reader.getFile(format, (file) async {
    try {
      final bytes = await file.readAll();
      if (!completer.isCompleted) completer.complete(bytes);
    } catch (_) {
      if (!completer.isCompleted) completer.complete(null);
    }
  }, onError: (_) {
    if (!completer.isCompleted) completer.complete(null);
  });
  if (progress == null && !completer.isCompleted) completer.complete(null);
  return completer.future.timeout(timeout, onTimeout: () => null);
}

String extensionForPasteFormat(SimpleFileFormat format) => switch (format) {
      Formats.png => 'png',
      Formats.jpeg => 'jpg',
      Formats.gif => 'gif',
      Formats.webp => 'webp',
      Formats.bmp => 'bmp',
      Formats.tiff => 'tiff',
      _ => 'png',
    };

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'at_rest.dart';

/// Copies the attachment at [diskPath] out to [destPath], decrypting on the way.
///
/// The one Save-as path for every surface. Rethrows so the caller can say what
/// failed; the copy it leaves outside the data root is plaintext.
Future<void> exportAttachmentTo(String diskPath, String destPath) async {
  await AtRest.exportTo(diskPath, destPath);
}

/// The Save-as confirmation, which has to say the copy is no longer protected.
String exportedCopyMessage(String destPath) =>
    'Saved an unprotected copy to ${_folderOf(destPath)}';

String _folderOf(String destPath) {
  try {
    return p.basename(File(destPath).parent.path);
  } catch (_) {
    return destPath;
  }
}

/// The desktop Save dialog for a file someone else named; null when cancelled.
///
/// The name only seeds a dialog the person confirms; it is made inert anyway,
/// so an accepted suggestion is always one file in the folder the dialog shows.
Future<String?> pickSavePathFor(
  String fileName, {
  required List<String> allowedExtensions,
  String dialogTitle = 'Save file',
}) =>
    FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: share_api.safeSaveName(raw: fileName),
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );

/// The phone Save sheet for [bytes] under a name someone else chose; null when
/// cancelled.
///
/// iOS's picker first writes `Documents/<name>`, deleting whatever is already
/// there (our `hollow` folder included), so the copy is staged in a folder of
/// its own, which goes once the sheet closes and takes the plaintext with it.
Future<String?> saveBytesFromPhone(
  String fileName,
  Uint8List bytes, {
  String dialogTitle = 'Save file',
}) async {
  final name = share_api.safeSaveName(raw: fileName);
  if (!Platform.isIOS) {
    return FilePicker.platform
        .saveFile(dialogTitle: dialogTitle, fileName: name, bytes: bytes);
  }
  await sweepStaleSaveStages();
  final stageName = '.save_${DateTime.now().microsecondsSinceEpoch}';
  final stage = Directory(
      p.join((await getApplicationDocumentsDirectory()).path, stageName));
  await stage.create();
  try {
    return await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle, fileName: '$stageName/$name', bytes: bytes);
  } finally {
    try {
      await stage.delete(recursive: true);
    } catch (_) {}
  }
}

final _saveStageName = RegExp(r'^\.save_\d+$');

/// Removes iOS Save staging folders a killed app left behind, each holding a
/// plaintext copy of a received file. Runs at launch and before every stage.
Future<void> sweepStaleSaveStages() async {
  if (!Platform.isIOS) return;
  try {
    final docs = await getApplicationDocumentsDirectory();
    await for (final entry in docs.list(followLinks: false)) {
      if (entry is Directory && _saveStageName.hasMatch(p.basename(entry.path))) {
        try {
          await entry.delete(recursive: true);
        } catch (_) {}
      }
    }
  } catch (_) {}
}

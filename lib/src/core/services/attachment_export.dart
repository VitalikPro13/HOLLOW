import 'dart:io';

import 'package:path/path.dart' as p;

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

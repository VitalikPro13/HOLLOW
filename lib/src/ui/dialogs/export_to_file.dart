import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart' as path_provider;

/// [name] as a file name: letters, digits, spaces and dashes kept, spaces
/// joined by underscores, lower case.
String exportFileStem(String name) {
  final stem = name
      .replaceAll(RegExp(r'[^\w\s\-]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_')
      .toLowerCase();
  return stem.isEmpty ? 'hollow' : stem;
}

/// Saves a file that Rust writes: [write] gets a path and returns the bytes
/// written. A desktop asks where first and Rust writes there; a phone has no
/// writable path to offer, so Rust writes a temp file whose bytes then go to
/// the system save sheet. Null when the person cancelled a picker.
///
/// [onWriting] runs once the destination is chosen, when the slow part
/// starts, so a dialog shows loading only after the picker closes.
Future<int?> exportToFile({
  required String fileName,
  required String extension,
  required String pickerTitle,
  required Future<BigInt> Function(String outputPath) write,
  void Function()? onWriting,
}) async {
  if (!(Platform.isAndroid || Platform.isIOS)) {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: pickerTitle,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    if (path == null) return null;
    onWriting?.call();
    return (await write(path)).toInt();
  }

  onWriting?.call();
  final temp = File(
      '${(await path_provider.getTemporaryDirectory()).path}/$fileName');
  try {
    final size = await write(temp.path);
    final saved = await FilePicker.platform.saveFile(
      dialogTitle: pickerTitle,
      fileName: fileName,
      bytes: await temp.readAsBytes(),
    );
    return saved == null ? null : size.toInt();
  } finally {
    try {
      await temp.delete();
    } catch (_) {}
  }
}

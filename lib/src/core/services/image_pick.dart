import 'dart:io' show File, Platform, Process, ProcessResult;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../rust/api/network.dart' as network_api;

/// Test-only seam: the UI probe arms this to answer the NEXT pick, because a
/// native picker is an OS modal no widget test can open or dismiss. Consumed
/// once, so an armed pick never leaks into a later one.
Future<Uint8List?> Function()? debugArmedImagePick;

/// Picks one image and returns its bytes. Null means the user cancelled.
///
/// Linux sessions without an xdg-desktop-portal backend make file_picker throw,
/// and that throw used to reach the zone handler with nothing on screen, so a
/// command-line dialog stands in there.
Future<Uint8List?> pickImageBytes({required List<String> extensions}) async {
  final armed = debugArmedImagePick;
  if (armed != null) {
    debugArmedImagePick = null;
    return armed();
  }

  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.first;
    // Some backends ignore withData and hand back only a path.
    final bytes = picked.bytes;
    if (bytes != null) return bytes;
    final path = picked.path;
    if (path == null) return null;
    return await File(path).readAsBytes();
  } catch (e) {
    _log('[HOLLOW-PICK] native picker failed: $e');
    if (!Platform.isLinux) rethrow;
    final fallback = await _pickViaCommandLine(extensions);
    if (!fallback.ran) rethrow;
    final path = fallback.path;
    if (path == null) return null;
    return await File(path).readAsBytes();
  }
}

/// Runs the first desktop dialog binary this session has. `ran` false means
/// none of them could start, which leaves the caller with its original error.
Future<({bool ran, String? path})> _pickViaCommandLine(
    List<String> extensions) async {
  final patterns = extensions.map((e) => '*.$e').join(' ');
  final tools = <(String, List<String>)>[
    (
      'zenity',
      [
        '--file-selection',
        '--title=Choose an image',
        '--file-filter=Images | $patterns',
      ]
    ),
    (
      'qarma',
      [
        '--file-selection',
        '--title=Choose an image',
        '--file-filter=Images | $patterns',
      ]
    ),
    ('kdialog', ['--getopenfilename', '.', 'Images ($patterns)']),
  ];

  for (final (exe, args) in tools) {
    ProcessResult run;
    try {
      run = await Process.run(exe, args);
    } catch (_) {
      continue;
    }
    if (run.exitCode != 0) return (ran: true, path: null); // cancelled
    final path = '${run.stdout}'.trim();
    return (ran: true, path: path.isEmpty ? null : path);
  }
  return (ran: false, path: null);
}

void _log(String line) {
  // Fire-and-forget FFI: an unstarted bridge throws synchronously while a
  // rejection lands on the zone handler, so both are swallowed here.
  try {
    network_api.logFromDart(message: line).catchError((_) {});
  } catch (_) {}
}

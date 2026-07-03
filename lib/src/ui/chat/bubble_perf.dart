import 'dart:io';

/// Shared per-row perf helpers for message bubbles. These run inside chat
/// list itemBuilders — once per visible row per rebuild — so no fresh RegExp
/// compiles or sync disk stats belong there.

/// Strips fenced code blocks before hollow:// link extraction. Hoisted:
/// bubbles used to compile a fresh RegExp per row per rebuild.
final RegExp codeBlockRegex = RegExp(r'```[\s\S]*?```');

/// Positive-only cache for reply-thumbnail file existence. `existsSync` is a
/// synchronous disk stat on the UI thread — fine once, not per row per
/// rebuild. Only positives are cached: an existing file is stable (deletion
/// degrades to the image error fallback), while a missing file can APPEAR
/// when its download completes, so negatives must be re-checked.
final Set<String> _knownExistingFiles = <String>{};

bool cachedFileExists(String path) {
  if (_knownExistingFiles.contains(path)) return true;
  final exists = File(path).existsSync();
  if (exists) {
    if (_knownExistingFiles.length > 512) _knownExistingFiles.clear();
    _knownExistingFiles.add(path);
  }
  return exists;
}

import 'dart:io';

/// Shared per-row perf helpers for message bubbles. These run inside chat list
/// itemBuilders, once per visible row per rebuild, so no fresh RegExp compile
/// or sync disk stat belongs there.

/// Strips fenced code blocks before hollow:// link extraction.
final RegExp codeBlockRegex = RegExp(r'```[\s\S]*?```');

/// Positive-only cache for reply-thumbnail file existence. A hit is stable
/// (deletion degrades to the image error fallback) but a miss can turn into a
/// hit when a download completes, so negatives are never cached.
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

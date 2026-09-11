import 'package:flutter/foundation.dart';

import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/rust/api/at_rest.dart' as ffi;

/// Progress of the one-per-boot sweep over files an older version left in the clear.
typedef AtRestStatus = ffi.AtRestStatus;

/// Reads, writes and exports for content files under the Hollow data root.
///
/// dart:io cannot read those files any more. A source outside the data root
/// passes through unchanged, so a call site never has to ask which it holds.
class AtRest {
  /// Replaces the read primitive in tests, where there is no FFI binding.
  @visibleForTesting
  static Future<Uint8List> Function(String path)? debugRead;

  static final Map<String, String> _mediaUrls = {};
  static final Map<String, Future<String>> _mediaUrlsInFlight = {};

  static Future<Uint8List> read(String path) {
    final override = debugRead;
    if (override != null) return override(path);
    return _read(path);
  }

  /// Replaces the ranged read in tests.
  @visibleForTesting
  static Future<Uint8List> Function(String path, int offset, int len)?
      debugReadRange;

  static Future<Uint8List> readRange(String path, int offset, int len) {
    final override = debugReadRange;
    if (override != null) return override(path, offset, len);
    return _readRange(path, offset, len);
  }

  static Future<void> write(String path, Uint8List bytes) =>
      _write(path, bytes);

  static Future<void> remove(String path) => _remove(path);

  /// Decrypts [srcPath] to [destPath], which is outside the data root and so
  /// stays plaintext.
  static Future<int> exportTo(String srcPath, String destPath) =>
      _exportTo(srcPath, destPath);

  /// A loopback URL for a player that takes a URL and not bytes. The port and
  /// token are new every launch, so the memo lasts only as long as the process.
  static Future<String> mediaUrlFor(String path) {
    final cached = _mediaUrls[path];
    if (cached != null) return Future.value(cached);
    // BLOCK body, never `() => _mediaUrlsInFlight.remove(path)`: Map.remove
    // returns this very future and whenComplete would then wait on itself.
    return _mediaUrlsInFlight[path] ??= _mediaUrl(path).then((url) {
      _mediaUrls[path] = url;
      return url;
    }).whenComplete(() {
      _mediaUrlsInFlight.remove(path);
    });
  }

  static Future<AtRestStatus> status() => _status();

  /// Whether [path] sits under the data root, and so is stored encrypted. Only
  /// for the few places that must hand a decoder a real file name or nothing.
  static bool isManaged(String path) {
    try {
      final root = _canonical(hollowDataDir);
      final candidate = _canonical(path);
      return candidate.startsWith(root.endsWith('/') ? root : '$root/');
    } catch (_) {
      return false;
    }
  }

  static String _canonical(String path) =>
      path.replaceAll('\\', '/').toLowerCase();

  static Future<Uint8List> _read(String path) => ffi.readAtRest(path: path);

  static Future<Uint8List> _readRange(String path, int offset, int len) =>
      ffi.readAtRestRange(
          path: path, offset: BigInt.from(offset), len: len);

  static Future<void> _write(String path, Uint8List bytes) =>
      ffi.writeAtRest(path: path, bytes: bytes);

  static Future<void> _remove(String path) => ffi.removeAtRest(path: path);

  static Future<int> _exportTo(String srcPath, String destPath) async =>
      (await ffi.exportAtRest(srcPath: srcPath, destPath: destPath)).toInt();

  static Future<String> _mediaUrl(String path) =>
      ffi.atRestMediaUrl(path: path);

  static Future<AtRestStatus> _status() => ffi.atRestStatus();
}

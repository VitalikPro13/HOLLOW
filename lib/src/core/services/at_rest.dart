import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/rust/api/at_rest.dart' as ffi;

/// Rust's `IMAGE_NOT_YET` (api/at_rest.rs): the file waits for a check slot, which is
/// not a refusal.
const String kImageNotYet = 'Hollow is still checking this image';

/// Runs [read] again while Rust is still checking the image it returns, one
/// second apart and at most [attempts] times ([waitFirst]: a second before the
/// first too); a refusal or any other failure is rethrown at once.
Future<T> whileImageChecked<T>(
  Future<T> Function() read, {
  int attempts = 60,
  bool waitFirst = false,
}) async {
  if (waitFirst) await Future<void>.delayed(AtRest.debugImageRetryDelay);
  for (var attempt = 1; ; attempt++) {
    try {
      return await read();
    } catch (e) {
      if (attempt >= attempts || !e.toString().contains(kImageNotYet)) rethrow;
      await Future<void>.delayed(AtRest.debugImageRetryDelay);
    }
  }
}

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

  /// Replaces the image read in tests.
  @visibleForTesting
  static Future<Uint8List> Function(String path)? debugReadImage;

  /// The bytes of an image file for Flutter's decoder, only once Rust has decoded
  /// them whole; throws for a file it refused, so the caller shows its fallback.
  /// While Rust is still waiting to check the file it asks again, up to a minute.
  static Future<Uint8List> readImage(String path) => whileImageChecked(() {
    final override = debugReadImage;
    return override != null ? override(path) : ffi.readAtRestImage(path: path);
  }, attempts: 61);

  /// The wait between two asks while Rust is still checking an image.
  @visibleForTesting
  static Duration debugImageRetryDelay = const Duration(seconds: 1);

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
    return _mediaUrlsInFlight[path] ??= _mediaUrl(path)
        .then((url) {
          _mediaUrls[path] = url;
          return url;
        })
        .whenComplete(() {
          _mediaUrlsInFlight.remove(path);
        });
  }

  static Future<AtRestStatus> status() => _status();

  /// Whether [path] sits under the data root, and so is stored encrypted. Only
  /// for the few places that must hand a decoder a real file name or nothing.
  ///
  /// Resolved like Rust's `under_data_root` (`..` and links followed on the
  /// part that exists); a path that cannot be resolved counts as managed, so
  /// it never reaches a decoder that would need a plaintext file.
  static bool isManaged(String path) {
    try {
      final root = _canonical(_resolved(hollowDataDir));
      final candidate = _canonical(_resolved(path));
      return candidate.startsWith(root.endsWith('/') ? root : '$root/');
    } catch (_) {
      return true;
    }
  }

  /// [path] with its deepest existing ancestor resolved by the OS; a missing
  /// tail that climbs (`..`) is refused, as `under_data_root` refuses it.
  static String _resolved(String path) {
    if (path.contains('\u0000')) throw ArgumentError.value(path, 'path');
    var anchor = p.absolute(path);
    final tail = <String>[];
    while (FileSystemEntity.typeSync(anchor) == FileSystemEntityType.notFound) {
      final name = p.basename(anchor);
      final parent = p.dirname(anchor);
      if (name == '..' || name == '.' || parent == anchor) {
        throw ArgumentError.value(path, 'path');
      }
      tail.add(name);
      anchor = parent;
    }
    final real = File(anchor).resolveSymbolicLinksSync();
    return p.joinAll([real, ...tail.reversed]);
  }

  static String _canonical(String path) =>
      path.replaceAll('\\', '/').toLowerCase();

  static Future<Uint8List> _read(String path) => ffi.readAtRest(path: path);

  static Future<Uint8List> _readRange(String path, int offset, int len) =>
      ffi.readAtRestRange(path: path, offset: BigInt.from(offset), len: len);

  static Future<void> _write(String path, Uint8List bytes) =>
      ffi.writeAtRest(path: path, bytes: bytes);

  static Future<void> _remove(String path) => ffi.removeAtRest(path: path);

  static Future<int> _exportTo(String srcPath, String destPath) async =>
      (await ffi.exportAtRest(srcPath: srcPath, destPath: destPath)).toInt();

  static Future<String> _mediaUrl(String path) =>
      ffi.atRestMediaUrl(path: path);

  static Future<AtRestStatus> _status() => ffi.atRestStatus();
}

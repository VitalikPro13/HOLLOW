import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../../rust/api/network.dart' as network_api;

void _dbg(String msg) {
  try {
    network_api
        .logFromDart(message: '[HOLLOW-GIF-THUMB] $msg')
        .catchError((_) {});
  } catch (_) {}
}

/// Disk and RAM cache for GIF picker thumbnails, so a restarted app still
/// shows the grid instantly.
///
/// Disk is a ~200 MB LRU by mtime that the OS is free to wipe: everything here
/// is refetchable public thumbnail data, never message content. RAM is a small
/// insertion-ordered tier for the visible grid. Only ever fed URLs from
/// [gifs_api.GifItem], which Rust already origin-checked against the proxy.
class GifThumbCache {
  GifThumbCache._();
  static final GifThumbCache instance = GifThumbCache._();

  static const _maxDiskBytes = 200 * 1024 * 1024;
  static const _maxRamEntries = 200;
  // The proxy caps cached media at 6 MB — anything bigger is not ours.
  static const _maxItemBytes = 6 * 1024 * 1024 + 65536;
  static const _sweepEveryWrites = 25;
  // Cold thumbnails burst 30+ at once when a grid page lands. Unbounded
  // parallel downloads each open their own TLS handshake and saturate both
  // the user's connection and the shared host's PHP workers, and the search
  // POST then starves behind them. Keep a small FIFO window.
  static const _maxConcurrentDownloads = 4;

  Future<Directory>? _dirFuture;
  final _ram = <String, Uint8List>{};
  final _inflight = <String, Future<Uint8List?>>{};
  int _writesSinceSweep = 0;
  int _activeDownloads = 0;
  final _downloadWaiters = <Completer<void>>[];
  HttpClient? _sharedClient;

  /// One shared keep-alive client: connection reuse instead of a fresh TLS
  /// handshake per thumbnail.
  HttpClient get _http => _sharedClient ??= HttpClient()
    ..maxConnectionsPerHost = _maxConcurrentDownloads
    ..idleTimeout = const Duration(seconds: 15);

  Future<void> _acquireDownloadSlot() {
    if (_activeDownloads < _maxConcurrentDownloads) {
      _activeDownloads++;
      return Future.value();
    }
    final waiter = Completer<void>();
    _downloadWaiters.add(waiter);
    return waiter.future;
  }

  void _releaseDownloadSlot() {
    if (_downloadWaiters.isNotEmpty) {
      _downloadWaiters.removeAt(0).complete();
    } else {
      _activeDownloads--;
    }
  }

  Future<Directory> _cacheDir() {
    return _dirFuture ??= () async {
      try {
        final base = await getApplicationCacheDirectory();
        final dir =
            Directory('${base.path}${Platform.pathSeparator}gif_thumbs');
        await dir.create(recursive: true);
        return dir;
      } catch (_) {
        // Never memoize a FAILED lookup: one transient miss would otherwise
        // disable the disk tier for the rest of the session.
        _dirFuture = null;
        rethrow;
      }
    }();
  }

  String _key(String url) => sha256.convert(utf8.encode(url)).toString();

  /// Bytes for a thumbnail URL: RAM, then disk, then network. Null on any
  /// failure, where callers render a placeholder.
  Future<Uint8List?> load(String url) {
    final ram = _ram.remove(url);
    if (ram != null) {
      _ram[url] = ram; // re-insert: keeps insertion order ≈ LRU
      return Future.value(ram);
    }
    // BLOCK BODY, NEVER `() => _inflight.remove(url)`: Map.remove returns the
    // removed value, this very future, and whenComplete waits for an
    // action-returned Future before completing. The arrow form deadlocks the
    // future on itself, so the caller's `.then` never runs and the cell never
    // paints. Same bug as GifCatalog.page().
    return _inflight[url] ??= _load(url).whenComplete(() {
      _inflight.remove(url);
    });
  }

  Future<Uint8List?> _load(String url) async {
    try {
      final dir = await _cacheDir();
      final file = File('${dir.path}${Platform.pathSeparator}${_key(url)}');
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        _ramPut(url, bytes);
        // Touch for LRU; best-effort (some filesystems refuse).
        try {
          file.setLastModifiedSync(DateTime.now());
        } catch (_) {}
        return bytes;
      }
      final bytes = await _download(url);
      if (bytes == null) return null;
      _ramPut(url, bytes);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
      if (++_writesSinceSweep >= _sweepEveryWrites) {
        _writesSinceSweep = 0;
        _sweep().catchError((_) {});
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  int _dlOk = 0;
  int _dlFail = 0;

  Future<Uint8List?> _download(String url) async {
    await _acquireDownloadSlot();
    final t0 = DateTime.now();
    try {
      final request = await _http
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        // Drain so the keep-alive connection can be reused.
        await response.drain<void>().catchError((_) {});
        _dlFail++;
        _dbg('download HTTP ${response.statusCode} in '
            '${DateTime.now().difference(t0).inMilliseconds}ms '
            '(ok=$_dlOk fail=$_dlFail)');
        return null;
      }
      final builder = BytesBuilder(copy: false);
      await response
          .forEach(builder.add)
          .timeout(const Duration(seconds: 30));
      if (builder.length == 0 || builder.length > _maxItemBytes) return null;
      _dlOk++;
      if (_dlOk % 15 == 0) {
        _dbg('downloads ok=$_dlOk fail=$_dlFail (last '
            '${builder.length}b in '
            '${DateTime.now().difference(t0).inMilliseconds}ms)');
      }
      return builder.takeBytes();
    } catch (e) {
      _dlFail++;
      _dbg('download ${e.runtimeType} in '
          '${DateTime.now().difference(t0).inMilliseconds}ms '
          '(ok=$_dlOk fail=$_dlFail)');
      // A response abandoned mid-body can wedge one of the shared client's
      // keep-alive connections, so recreate the client rather than let four
      // wedged sockets brick all future thumbnail downloads.
      _sharedClient?.close(force: true);
      _sharedClient = null;
      return null;
    } finally {
      _releaseDownloadSlot();
    }
  }

  void _ramPut(String url, Uint8List bytes) {
    _ram.remove(url);
    _ram[url] = bytes;
    while (_ram.length > _maxRamEntries) {
      _ram.remove(_ram.keys.first);
    }
  }

  /// Total bytes on disk (Storage Manager display).
  Future<int> sizeBytes() async {
    try {
      final dir = await _cacheDir();
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) {
          total += await e.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Wipe the cache (Storage Manager cleanup action).
  Future<void> clear() async {
    _ram.clear();
    try {
      final dir = await _cacheDir();
      await for (final e in dir.list()) {
        try {
          await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _sweep() async {
    final dir = await _cacheDir();
    final files = <(File, DateTime, int)>[];
    var total = 0;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      try {
        final stat = await e.stat();
        files.add((e, stat.modified, stat.size));
        total += stat.size;
      } catch (_) {}
    }
    if (total <= _maxDiskBytes) return;
    files.sort((a, b) => a.$2.compareTo(b.$2)); // oldest first
    // Hysteresis to 90% so consecutive writes do not each trigger a sweep.
    final target = (_maxDiskBytes * 0.9).round();
    for (final (file, _, size) in files) {
      if (total <= target) break;
      try {
        await file.delete();
        total -= size;
      } catch (_) {}
    }
  }
}

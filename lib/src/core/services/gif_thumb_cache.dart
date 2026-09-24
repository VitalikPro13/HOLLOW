import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../rust/api/network.dart' as network_api;

void _dbg(String msg) {
  try {
    network_api
        .logFromDart(message: '[HOLLOW-GIF-THUMB] $msg')
        .catchError((_) {});
  } catch (_) {}
}

/// RAM cache for GIF and sticker picker thumbnails, for this session only.
///
/// Never on disk: search results change on every search, and what a person
/// keeps is saved (and counted) as an asset, so a disk tier only ever held
/// stale previews. Bounded by entries AND bytes, since an animated preview can
/// be megabytes. Only ever fed URLs from [gifs_api.GifItem], which Rust
/// already origin-checked against the proxy.
class GifThumbCache {
  GifThumbCache._();
  static final GifThumbCache instance = GifThumbCache._();

  static const _maxRamEntries = 200;
  static const _maxRamBytes = 48 * 1024 * 1024;
  // The proxy caps cached media at 6 MB — anything bigger is not ours.
  static const _maxItemBytes = 6 * 1024 * 1024 + 65536;
  // Cold thumbnails burst 30+ at once when a grid page lands. Unbounded
  // parallel downloads each open their own TLS handshake and saturate both
  // the user's connection and the shared host's PHP workers, and the search
  // POST then starves behind them. Keep a small FIFO window.
  static const _maxConcurrentDownloads = 4;

  final _ram = <String, Uint8List>{};
  int _ramBytes = 0;
  final _inflight = <String, Future<Uint8List?>>{};
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

  /// Bytes for a thumbnail URL: RAM, then network. Null on any failure, where
  /// callers render a placeholder.
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
    final bytes = await _download(url);
    if (bytes != null) _ramPut(url, bytes);
    return bytes;
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
    final previous = _ram.remove(url);
    if (previous != null) _ramBytes -= previous.length;
    _ram[url] = bytes;
    _ramBytes += bytes.length;
    while (_ram.length > _maxRamEntries || _ramBytes > _maxRamBytes) {
      final oldest = _ram.keys.first;
      _ramBytes -= _ram.remove(oldest)!.length;
    }
  }

  /// Deletes the disk tier older versions kept (up to 200 MB of stale
  /// previews). Run once per launch, off the UI's critical path.
  static Future<void> purgeLegacyDiskCache() async {
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}gif_thumbs');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      _dbg('legacy disk cache purge failed: ${e.runtimeType}');
    }
  }
}

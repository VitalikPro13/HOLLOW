import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../rust/api/catalog.dart' as catalog_api;
import '../../rust/api/network.dart' as network_api;
import 'at_rest.dart';

void _dbg(String msg) {
  try {
    network_api
        .logFromDart(message: '[HOLLOW-GIF-THUMB] $msg')
        .catchError((_) {});
  } catch (_) {}
}

/// RAM cache for catalog previews (GIF, sticker, FFZ and IGDB pickers), for
/// this session only.
///
/// Never on disk: search results change on every search, and what a person
/// keeps is saved (and counted) as an asset, so a disk tier only ever held
/// stale previews. Bounded by entries AND bytes, since an animated preview can
/// be megabytes. Rust fetches each one, from the catalog addresses alone, and
/// hands it over only once its image check decoded it whole (AR-28).
class GifThumbCache {
  GifThumbCache._();
  static final GifThumbCache instance = GifThumbCache._();

  static const _maxRamEntries = 200;
  static const _maxRamBytes = 48 * 1024 * 1024;
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

  /// Replaces the Rust fetch in tests, where there is no FFI binding.
  @visibleForTesting
  static Future<Uint8List> Function(String url)? debugFetch;

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
    final t0 = DateTime.now();
    try {
      final fetch = debugFetch ??
          (String u) => catalog_api.fetchCatalogPreview(url: u);
      final bytes = await _firstAsk(() => fetch(url)) ??
          // Rust kept what it fetched: later asks judge those bytes again and
          // download nothing, so they wait without a download slot.
          await whileImageChecked<Uint8List>(() => fetch(url),
              attempts: 9, waitFirst: true);
      _dlOk++;
      if (_dlOk % 15 == 0) {
        _dbg('downloads ok=$_dlOk fail=$_dlFail (last '
            '${bytes.length}b in '
            '${DateTime.now().difference(t0).inMilliseconds}ms)');
      }
      return bytes;
    } catch (e) {
      _dlFail++;
      _dbg('download ${e.runtimeType} in '
          '${DateTime.now().difference(t0).inMilliseconds}ms '
          '(ok=$_dlOk fail=$_dlFail)');
      return null;
    }
  }

  /// The one ask that may download, under a download slot: its bytes, or null
  /// while the image check is still on them.
  Future<Uint8List?> _firstAsk(Future<Uint8List> Function() fetch) async {
    await _acquireDownloadSlot();
    try {
      return await fetch();
    } catch (e) {
      if (e.toString().contains(kImageNotYet)) return null;
      rethrow;
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

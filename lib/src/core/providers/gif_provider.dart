import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/gifs.dart' as gifs_api;
import '../../rust/api/storage.dart' as storage_api;
import '../services/gif_thumb_cache.dart';

/// Default GIF proxy base (the Hollow website's no-log Klipy proxy). Keep in
/// sync with DEFAULT_GIF_PROXY in rust api/gifs.rs.
const kDefaultGifProxyUrl = 'https://hollow.anonlisten.com/gifs/';
const _kGifProxySettingKey = 'gif_proxy_url';

/// Self-hoster override for the GIF proxy base URL. Mirrors the
/// relayDomainProvider pattern: persisted in the encrypted settings store,
/// pushed to Rust explicitly at startup (never rely on a lazy provider
/// build reaching Rust).
class GifProxyUrlNotifier extends Notifier<String> {
  @override
  String build() => kDefaultGifProxyUrl;

  Future<void> loadCached() async {
    try {
      final saved = await storage_api.loadSetting(key: _kGifProxySettingKey);
      if (saved == null || saved.isEmpty) return;
      // Rust validates (https, trailing slash); an invalid persisted value
      // is ignored and the default stays active.
      await gifs_api.setGifProxyUrl(base: saved);
      state = saved;
    } catch (_) {}
  }

  /// Rethrows on an invalid URL — call sites await + toast.
  Future<void> setUrl(String raw) async {
    final v = raw.trim();
    if (v.isEmpty || v == kDefaultGifProxyUrl) {
      await gifs_api.setGifProxyUrl(base: null);
      state = kDefaultGifProxyUrl;
      await storage_api.saveSetting(key: _kGifProxySettingKey, value: '');
    } else {
      await gifs_api.setGifProxyUrl(base: v); // validates, throws on bad input
      state = v;
      await storage_api.saveSetting(key: _kGifProxySettingKey, value: v);
    }
  }
}

final gifProxyUrlProvider =
    NotifierProvider<GifProxyUrlNotifier, String>(GifProxyUrlNotifier.new);

class _CachedPage {
  final gifs_api.GifPage page;
  final DateTime at;
  _CachedPage(this.page) : at = DateTime.now();
}

/// Session RAM cache over the GIF proxy FFI. The website proxy does the real
/// caching — this layer only avoids re-hitting it within a session and keeps
/// picker-open spinner-free via [prefetchTrending].
///
/// Methods are overridable so widget tests can fake the catalog through
/// [gifCatalogProvider].
class GifCatalog {
  final Map<String, _CachedPage> _pages = {};
  final Map<String, Future<gifs_api.GifPage>> _inflight = {};
  List<String>? _categories;
  Future<List<String>>? _categoriesInflight;

  static const _trendingTtl = Duration(minutes: 10);
  static const _searchTtl = Duration(hours: 1);

  /// Synchronous cache read — lets the picker render a warm page with no
  /// spinner frame at all. Null when cold or expired.
  gifs_api.GifPage? peek(String query, int page) {
    final q = query.trim().toLowerCase();
    final cached = _pages['$q|$page'];
    if (cached == null) return null;
    final ttl = q.isEmpty ? _trendingTtl : _searchTtl;
    return DateTime.now().difference(cached.at) < ttl ? cached.page : null;
  }

  /// One page of trending (`query == ''`) or search results.
  Future<gifs_api.GifPage> page(String query, int page) {
    final q = query.trim().toLowerCase();
    final key = '$q|$page';
    final cached = _pages[key];
    if (cached != null) {
      final ttl = q.isEmpty ? _trendingTtl : _searchTtl;
      if (DateTime.now().difference(cached.at) < ttl) {
        return Future.value(cached.page);
      }
      _pages.remove(key);
    }
    final inflight = _inflight[key];
    if (inflight != null) return inflight;
    // The hard timeout outlives the Rust-side 20s reqwest timeout — pure
    // insurance so a lost FFI future can never pin the UI (and, via the
    // inflight dedup above, every later identical query) on a spinner
    // forever. On timeout the key is freed and the next attempt retries.
    final future = fetchPage(q, page)
        .timeout(const Duration(seconds: 25))
        .then((p) {
      // Never cache a backoff/empty page as if it were an answer.
      if (p.items.isNotEmpty) _pages[key] = _CachedPage(p);
      return p;
      // BLOCK BODY BELOW, NEVER `() => _inflight.remove(key)`: Map.remove
      // returns the removed value — which here IS this very future — and
      // whenComplete defers its own completion until an action-returned
      // Future completes. The arrow form makes the future wait on itself:
      // the inner .then still runs (so the RAM cache warms) but nothing
      // downstream ever fires. That was the "picker spins forever, yet
      // reopening it shows results" bug.
    }).whenComplete(() {
      _inflight.remove(key);
    });
    _inflight[key] = future;
    return future;
  }

  /// Category names for the browse chips (session-cached; server holds 7d).
  Future<List<String>> categories() {
    final cached = _categories;
    if (cached != null) return Future.value(cached);
    final inflight = _categoriesInflight;
    if (inflight != null) return inflight;
    final future = fetchCategories()
        .timeout(const Duration(seconds: 25))
        .then((names) {
      if (names.isNotEmpty) _categories = names;
      return names;
      // Safe as an arrow only because an assignment expression evaluates to
      // the assigned value (null), not to a Future — see the note above.
    }).whenComplete(() => _categoriesInflight = null);
    _categoriesInflight = future;
    return future;
  }

  /// The single raw-FFI seam for pages. Overridable so tests can exercise the
  /// caching / in-flight / timeout logic above it for real — faking [page]
  /// itself hides bugs that live in exactly that layer.
  @protected
  Future<gifs_api.GifPage> fetchPage(String query, int page) => query.isEmpty
      ? gifs_api.gifTrending(page: page)
      : gifs_api.gifSearch(query: query, page: page);

  /// Raw-FFI seam for categories (see [fetchPage]).
  @protected
  Future<List<String>> fetchCategories() => gifs_api.gifCategories();

  /// Fire-and-forget warm-up so the picker opens straight onto results —
  /// the page JSON plus the first screenful of still thumbnails (download
  /// concurrency is bounded inside GifThumbCache, so this stays gentle).
  void prefetchTrending() {
    // try/catch AND catchError: an uninitialized bridge throws synchronously.
    try {
      page('', 1).then((p) {
        for (final item in p.items.take(10)) {
          GifThumbCache.instance.load(item.stillUrl).catchError((_) => null);
        }
        return p;
      }).catchError((_) => const gifs_api.GifPage(
          items: [], page: 1, hasNext: false, backoffUntil: 0));
    } catch (_) {}
  }
}

final gifCatalogProvider = Provider<GifCatalog>((ref) => GifCatalog());

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/gifs.dart' as gifs_api;
import '../../rust/api/storage.dart' as storage_api;
import '../services/gif_thumb_cache.dart';

/// Default GIF proxy base. Keep in sync with DEFAULT_GIF_PROXY in rust api/gifs.rs.
const kDefaultGifProxyUrl = 'https://hollow.anonlisten.com/gifs/';
const _kGifProxySettingKey = 'gif_proxy_url';
const _kGifApiKeySettingKey = 'gif_api_key';
const _kGifRatingSettingKey = 'gif_rating';
const _kGifMediaHostsSettingKey = 'gif_media_hosts';
const _kGifAutoplaySettingKey = 'gif_autoplay';

/// Content rating the picker starts on; Rust owns the authoritative default
/// and the valid set. Keep in sync with rust api/gifs.rs.
const kDefaultGifRating = 'pg-13';

/// Self-hoster override for the GIF proxy base URL. Persisted in the encrypted
/// settings store and pushed to Rust explicitly at startup, never lazily.
class GifProxyUrlNotifier extends Notifier<String> {
  @override
  String build() => kDefaultGifProxyUrl;

  Future<void> loadCached() async {
    try {
      final saved = await storage_api.loadSetting(key: _kGifProxySettingKey);
      if (saved == null || saved.isEmpty) return;
      // Rust validates (https, trailing slash); an invalid value keeps the default.
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
    _onGifSourceChanged(ref);
  }
}

final gifProxyUrlProvider =
    NotifierProvider<GifProxyUrlNotifier, String>(GifProxyUrlNotifier.new);

/// The user's own Klipy API key (`''` = none = proxy mode). A key present IS
/// direct mode, so "enabled but no key" cannot happen. NOT a privacy upgrade:
/// Klipy then sees the user's IP and every search under one stable key.
class GifApiKeyNotifier extends Notifier<String> {
  @override
  String build() => '';

  Future<void> loadCached() async {
    try {
      final saved = await storage_api.loadSetting(key: _kGifApiKeySettingKey);
      if (saved == null || saved.isEmpty) return;
      await gifs_api.setGifApiKey(key: saved);
      state = saved;
    } catch (_) {}
  }

  /// Rethrows on a malformed key — call sites await + toast.
  Future<void> setKey(String raw) async {
    final v = raw.trim();
    // Rust validates the charset (the key rides in a URL path segment).
    await gifs_api.setGifApiKey(key: v.isEmpty ? null : v);
    state = v;
    await storage_api.saveSetting(key: _kGifApiKeySettingKey, value: v);
    _onGifSourceChanged(ref);
  }
}

final gifApiKeyProvider =
    NotifierProvider<GifApiKeyNotifier, String>(GifApiKeyNotifier.new);

final gifDirectModeProvider =
    Provider<bool>((ref) => ref.watch(gifApiKeyProvider).isNotEmpty);

/// Content rating sent with every search; the picker clamps it further outside
/// servers that are not flagged NSFW.
class GifRatingNotifier extends Notifier<String> {
  @override
  String build() => kDefaultGifRating;

  Future<void> loadCached() async {
    try {
      final saved = await storage_api.loadSetting(key: _kGifRatingSettingKey);
      if (saved == null || saved.isEmpty) return;
      final allowed = await gifs_api.gifRatings();
      if (allowed.contains(saved)) state = saved;
    } catch (_) {}
  }

  Future<void> setRating(String raw) async {
    final v = raw.trim().toLowerCase();
    if (v == state) return;
    state = v;
    // Results are cached per rating, so nothing stale can survive this.
    await storage_api.saveSetting(key: _kGifRatingSettingKey, value: v);
  }
}

final gifRatingProvider =
    NotifierProvider<GifRatingNotifier, String>(GifRatingNotifier.new);

/// The ratings Rust accepts, mildest first — read, never mirrored.
final gifRatingsProvider =
    FutureProvider<List<String>>((ref) => gifs_api.gifRatings());

/// The rating a picker actually sends: the user's setting, capped at `pg-13`
/// inside a server not flagged NSFW. A DM or conference passes through.
String clampGifRating(String rating, {required bool serverAllowsNsfw}) =>
    (!serverAllowsNsfw && rating == 'r') ? 'pg-13' : rating;

/// Whether picker cells animate on their own. ON by default. A DATA setting as
/// much as a motion one: autoplay downloads the animated variant for every cell
/// on screen, where hover-to-play fetches one. Reduce-motion always wins.
class GifAutoplayNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> loadCached() async {
    try {
      final saved = await storage_api.loadSetting(key: _kGifAutoplaySettingKey);
      if (saved == null || saved.isEmpty) return;
      state = saved == '1';
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    if (value == state) return;
    state = value;
    try {
      await storage_api.saveSetting(
          key: _kGifAutoplaySettingKey, value: value ? '1' : '0');
    } catch (_) {}
  }
}

final gifAutoplayProvider =
    NotifierProvider<GifAutoplayNotifier, bool>(GifAutoplayNotifier.new);

/// Media hosts direct mode may fetch grid images from. Suffix-matched, and
/// editable because a CDN move would otherwise need an app release.
class GifMediaHostsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  Future<List<String>> defaults() => gifs_api.defaultGifMediaHosts();

  Future<void> loadCached() async {
    try {
      final saved =
          await storage_api.loadSetting(key: _kGifMediaHostsSettingKey);
      final hosts = (saved ?? '')
          .split(',')
          .map((h) => h.trim())
          .where((h) => h.isNotEmpty)
          .toList();
      if (hosts.isEmpty) {
        state = await defaults();
        return;
      }
      await gifs_api.setGifMediaHosts(hosts: hosts);
      state = hosts;
    } catch (_) {
      try {
        state = await defaults();
      } catch (_) {}
    }
  }

  /// Rethrows on an invalid host. An empty list resets to the shipped defaults.
  Future<void> setHosts(List<String> raw) async {
    final hosts =
        raw.map((h) => h.trim()).where((h) => h.isNotEmpty).toList();
    await gifs_api.setGifMediaHosts(hosts: hosts);
    state = hosts.isEmpty ? await defaults() : hosts;
    await storage_api.saveSetting(
        key: _kGifMediaHostsSettingKey, value: state.join(','));
    _onGifSourceChanged(ref);
  }
}

final gifMediaHostsProvider =
    NotifierProvider<GifMediaHostsNotifier, List<String>>(
        GifMediaHostsNotifier.new);

/// Hosts whose media was refused since the last settings change, so a CDN move
/// is a two-tap fix rather than a mystery empty grid. Invalidate to re-read.
final gifBlockedHostsProvider =
    FutureProvider<List<String>>((ref) => gifs_api.gifBlockedMediaHosts());

/// Anything that changes WHERE results come from invalidates cached pages: the
/// two modes hand out different URLs for the same GIF id.
void _onGifSourceChanged(Ref ref) {
  ref.read(gifCatalogProvider).clear();
  ref.invalidate(gifBlockedHostsProvider);
}

class _CachedPage {
  final gifs_api.GifPage page;
  final DateTime at;
  _CachedPage(this.page) : at = DateTime.now();
}

/// Session RAM cache over the GIF proxy FFI; the website proxy does the real
/// caching. Methods are overridable so tests can fake [gifCatalogProvider].
class GifCatalog {
  final Map<String, _CachedPage> _pages = {};
  final Map<String, Future<gifs_api.GifPage>> _inflight = {};
  List<String>? _categories;
  Future<List<String>>? _categoriesInflight;

  static const _trendingTtl = Duration(minutes: 10);
  static const _searchTtl = Duration(hours: 1);

  /// Cache key. The RATING is part of it: a rating switch must not serve stale results.
  static String _key(String query, int page, String rating) =>
      '$rating|$query|$page';

  /// Synchronous cache read, so the picker renders a warm page with no spinner.
  gifs_api.GifPage? peek(String query, int page, String rating) {
    final q = query.trim().toLowerCase();
    final cached = _pages[_key(q, page, rating)];
    if (cached == null) return null;
    final ttl = q.isEmpty ? _trendingTtl : _searchTtl;
    return DateTime.now().difference(cached.at) < ttl ? cached.page : null;
  }

  /// Drop every cached page and category list, on any GIF SOURCE change: proxy
  /// and direct mode hand out different URLs for the same id.
  void clear() {
    _pages.clear();
    _categories = null;
  }

  /// One page of trending (`query == ''`) or search results.
  Future<gifs_api.GifPage> page(String query, int page, String rating) {
    final q = query.trim().toLowerCase();
    final key = _key(q, page, rating);
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
    // The hard timeout outlives the Rust-side 20s reqwest timeout, so a lost FFI
    // future can never pin the UI (and every later identical query) on a spinner.
    final future = fetchPage(q, page, rating)
        .timeout(const Duration(seconds: 25))
        .then((p) {
      // Never cache a backoff/empty page as if it were an answer.
      if (p.items.isNotEmpty) _pages[key] = _CachedPage(p);
      return p;
      // BLOCK BODY BELOW, NEVER `() => _inflight.remove(key)`: Map.remove returns
      // the removed value, which IS this very future, and whenComplete waits on an
      // action-returned Future, so the arrow form makes it wait on itself.
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
      // Safe as an arrow only because an assignment evaluates to the assigned value.
    }).whenComplete(() => _categoriesInflight = null);
    _categoriesInflight = future;
    return future;
  }

  /// The single raw-FFI seam for pages. Overridable so tests exercise the
  /// caching / in-flight / timeout logic for real; faking [page] hides those bugs.
  @protected
  Future<gifs_api.GifPage> fetchPage(String query, int page, String rating) =>
      query.isEmpty
          ? gifs_api.gifTrending(page: page, rating: rating)
          : gifs_api.gifSearch(query: query, page: page, rating: rating);

  @protected
  Future<List<String>> fetchCategories() => gifs_api.gifCategories();

  /// Fire-and-forget warm-up so the picker opens straight onto results: the page
  /// JSON plus the first screenful of thumbnails (concurrency bounded inside).
  void prefetchTrending(String rating) {
    // try/catch AND catchError: an uninitialized bridge throws synchronously.
    try {
      page('', 1, rating).then((p) {
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

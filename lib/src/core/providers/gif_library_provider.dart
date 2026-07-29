import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/gifs.dart' as gifs_api;
import '../../rust/api/storage.dart' as storage_api;
import 'gif_provider.dart';

/// Local GIF library: recently used, favourites, and user-made lists for
/// sorting favourites. Persisted as one JSON blob in the encrypted settings
/// store (no schema migration to keep in step with Rust, and it never leaves
/// the device — none of this is CRDT/wire state).
const _kLibrarySettingKey = 'gif_library';

const _kMaxRecents = 60;
const _kMaxFavorites = 500;
const _kMaxCollections = 20;

/// Longest a user-made list name may be.
const kMaxGifListNameLength = 32;

/// Media paths are stored RELATIVE to the proxy base and rebuilt against the
/// CURRENT base on load. Two reasons, both load-bearing:
///   * a stored absolute URL is a stored fetch target — a tampered row could
///     point the thumbnail cache at a foreign host, which is exactly what the
///     Rust-side origin check exists to prevent;
///   * a self-hoster who changes their proxy keeps their favourites working.
/// Shape mirrors gifs/.htaccess: `m/<id>.still.webp`, `m/<id>.sm.<ext>`.
final _mediaPathRe =
    RegExp(r'^m/[A-Za-z0-9_-]{1,100}\.(?:still|sm)\.[a-z0-9]{2,5}$');

/// The pick-time source path shape, also from gifs/.htaccess: `f/<id>`.
final _fullPathRe = RegExp(r'^f/[A-Za-z0-9_-]{1,100}$');

/// DIRECT MODE is the exception to the rule above: Klipy CDN paths are opaque
/// and cannot be rebuilt from an id, so those rows store the absolute https
/// URL Rust already host-checked at parse time. The guard moves rather than
/// disappearing — [GifLibraryNotifier.revalidate] re-asks Rust which stored
/// locations may be fetched in the CURRENT configuration, and rows it refuses
/// are hidden (never deleted: switch back and they return). The case that
/// matters: a CDN URL saved with your own key must NOT be fetched after you
/// go back to the proxy, which is the whole point of the proxy.
bool _isAbsoluteMedia(String v) => v.startsWith('https://');

bool _validMediaLocation(String v, [RegExp? relativeShape]) =>
    _isAbsoluteMedia(v) || (relativeShape ?? _mediaPathRe).hasMatch(v);

/// One GIF remembered locally. Carries exactly what the picker grid needs, so
/// favourites render without ever re-querying the proxy.
class SavedGif {
  final String id;
  final int w;
  final int h;
  final String title;

  /// Proxy-relative media paths (see [_mediaPathRe]) — or, for direct-mode
  /// picks, absolute https CDN URLs (see [_isAbsoluteMedia]).
  final String stillPath;
  final String smPath;

  /// Where the full-quality bytes come from when this row is SENT. Carried
  /// because direct mode's in-RAM variant registry only covers the current
  /// session: without it, sending a favourite saved last week would fail.
  final String fullPath;

  const SavedGif({
    required this.id,
    required this.w,
    required this.h,
    required this.title,
    required this.stillPath,
    required this.smPath,
    required this.fullPath,
  });

  /// Under [base] → stored relative. Otherwise absolute (a direct-mode pick;
  /// Rust host-checked it at parse time). Null when neither shape fits — for
  /// proxy rows that means the base changed between the search and the pick.
  static SavedGif? fromItem(gifs_api.GifItem item, String base) {
    String? location(String url, {RegExp? relativeShape}) {
      if (url.startsWith(base)) {
        final rel = url.substring(base.length);
        return (relativeShape ?? _mediaPathRe).hasMatch(rel) ? rel : null;
      }
      return _isAbsoluteMedia(url) ? url : null;
    }

    final still = location(item.stillUrl);
    final sm = location(item.smUrl);
    final full = location(item.fullUrl, relativeShape: _fullPathRe);
    if (still == null || sm == null || full == null) return null;
    return SavedGif(
      id: item.id,
      w: item.w,
      h: item.h,
      title: item.title,
      stillPath: still,
      smPath: sm,
      fullPath: full,
    );
  }

  /// The stored locations as fetchable URLs — what [GifLibraryNotifier]
  /// hands to Rust for a permission verdict.
  List<String> resolvedUrls(String base) => [
        _isAbsoluteMedia(stillPath) ? stillPath : '$base$stillPath',
        _isAbsoluteMedia(smPath) ? smPath : '$base$smPath',
        _isAbsoluteMedia(fullPath) ? fullPath : '$base$fullPath',
      ];

  gifs_api.GifItem toItem(String base) {
    final urls = resolvedUrls(base);
    return gifs_api.GifItem(
      id: id,
      w: w,
      h: h,
      title: title,
      stillUrl: urls[0],
      smUrl: urls[1],
      fullUrl: urls[2],
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'w': w,
        'h': h,
        't': title,
        'p': stillPath,
        's': smPath,
        'f': fullPath,
      };

  /// Tolerant by design: one unreadable row must never take the library with
  /// it (same reasoning as `#[serde(default)]` on the Rust structs).
  static SavedGif? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final w = raw['w'];
    final h = raw['h'];
    final still = raw['p'];
    final sm = raw['s'];
    if (id is! String || id.isEmpty) return null;
    if (w is! int || h is! int || w <= 0 || h <= 0) return null;
    if (still is! String || !_validMediaLocation(still)) return null;
    if (sm is! String || !_validMediaLocation(sm)) return null;
    // Rows written before the pick-source was carried (proxy-only builds)
    // rebuild it from the id — the endpoint shape is ours.
    final rawFull = raw['f'];
    final full = rawFull is String && _validMediaLocation(rawFull, _fullPathRe)
        ? rawFull
        : 'f/$id';
    final title = raw['t'];
    return SavedGif(
      id: id,
      w: w,
      h: h,
      title: title is String ? title : '',
      stillPath: still,
      smPath: sm,
      fullPath: full,
    );
  }
}

/// A user-made list for sorting favourites ("Reactions", "Cats", …).
class GifCollection {
  final String id;
  final String name;
  final List<String> gifIds;

  const GifCollection(
      {required this.id, required this.name, required this.gifIds});

  GifCollection copyWith({String? name, List<String>? gifIds}) =>
      GifCollection(id: id, name: name ?? this.name, gifIds: gifIds ?? this.gifIds);

  Map<String, Object?> toJson() => {'id': id, 'n': name, 'g': gifIds};

  static GifCollection? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['n'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final ids = raw['g'];
    return GifCollection(
      id: id,
      name: name,
      gifIds: ids is List ? ids.whereType<String>().toList() : const [],
    );
  }
}

class GifLibrary {
  /// Newest first.
  final List<SavedGif> recents;

  /// Newest first.
  final List<SavedGif> favorites;
  final List<GifCollection> collections;

  /// Stored media locations Rust refuses to fetch in the CURRENT
  /// configuration. NEVER persisted and never removed from the lists above:
  /// a row hidden because you dropped your Klipy key reappears when you put
  /// it back. See [GifLibraryNotifier.revalidate].
  final Set<String> hiddenLocations;

  const GifLibrary({
    this.recents = const [],
    this.favorites = const [],
    this.collections = const [],
    this.hiddenLocations = const {},
  });

  static const empty = GifLibrary();

  bool _shown(SavedGif g) =>
      !hiddenLocations.contains(g.stillPath) &&
      !hiddenLocations.contains(g.smPath) &&
      !hiddenLocations.contains(g.fullPath);

  /// Rows the picker may actually render — everything below the UI should
  /// use these, not the raw lists (which stay whole for persistence).
  List<SavedGif> get visibleRecents =>
      hiddenLocations.isEmpty ? recents : recents.where(_shown).toList();

  List<SavedGif> get visibleFavorites =>
      hiddenLocations.isEmpty ? favorites : favorites.where(_shown).toList();

  bool isFavorite(String id) => favorites.any((g) => g.id == id);

  /// Favourites in [collectionId], in favourites order. Null id = all.
  List<SavedGif> favoritesIn(String? collectionId) {
    if (collectionId == null) return visibleFavorites;
    final i = collections.indexWhere((c) => c.id == collectionId);
    if (i < 0) return const [];
    final ids = collections[i].gifIds.toSet();
    return favorites.where((g) => ids.contains(g.id) && _shown(g)).toList();
  }

  GifLibrary copyWith({
    List<SavedGif>? recents,
    List<SavedGif>? favorites,
    List<GifCollection>? collections,
    Set<String>? hiddenLocations,
  }) =>
      GifLibrary(
        recents: recents ?? this.recents,
        favorites: favorites ?? this.favorites,
        collections: collections ?? this.collections,
        hiddenLocations: hiddenLocations ?? this.hiddenLocations,
      );

  String encode() => jsonEncode({
        'recents': recents.map((g) => g.toJson()).toList(),
        'favorites': favorites.map((g) => g.toJson()).toList(),
        'collections': collections.map((c) => c.toJson()).toList(),
      });

  static GifLibrary decode(String raw) {
    if (raw.isEmpty) return empty;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return empty;
      List<SavedGif> gifs(Object? v) => v is List
          ? v.map(SavedGif.fromJson).whereType<SavedGif>().toList()
          : const [];
      final collections = map['collections'];
      return GifLibrary(
        recents: gifs(map['recents']),
        favorites: gifs(map['favorites']),
        collections: collections is List
            ? collections
                .map(GifCollection.fromJson)
                .whereType<GifCollection>()
                .toList()
            : const [],
      );
    } catch (_) {
      return empty;
    }
  }
}

class GifLibraryNotifier extends Notifier<GifLibrary> {
  @override
  GifLibrary build() {
    // Changing the GIF SOURCE flips which stored rows may be fetched at all
    // (see [revalidate]). ref.listen in build() is the registration point —
    // an initState-style hook would silently no-op here.
    ref.listen(gifDirectModeProvider, (_, _) => revalidate());
    ref.listen(gifMediaHostsProvider, (_, _) => revalidate());
    ref.listen(gifProxyUrlProvider, (_, _) => revalidate());
    return GifLibrary.empty;
  }

  String get _base => ref.read(gifProxyUrlProvider);

  /// Ask Rust which stored media locations may be fetched right now — the
  /// proxy base, the user's own key and the media allowlist all feed that
  /// answer — and hide the rest. Nothing is deleted; see
  /// [GifLibrary.hiddenLocations].
  Future<void> revalidate() async {
    try {
      final base = _base;
      final rows = [...state.recents, ...state.favorites];
      if (rows.isEmpty) {
        if (state.hiddenLocations.isNotEmpty) {
          state = state.copyWith(hiddenLocations: const {});
        }
        return;
      }
      // Resolved URL -> stored location, so verdicts map back to rows.
      final byUrl = <String, String>{};
      for (final g in rows) {
        final urls = g.resolvedUrls(base);
        byUrl[urls[0]] = g.stillPath;
        byUrl[urls[1]] = g.smPath;
        byUrl[urls[2]] = g.fullPath;
      }
      final urls = byUrl.keys.toList();
      final verdicts = await gifs_api.gifMediaUrlsPermitted(urls: urls);
      final hidden = <String>{};
      for (var i = 0; i < urls.length && i < verdicts.length; i++) {
        if (!verdicts[i]) hidden.add(byUrl[urls[i]]!);
      }
      final same = hidden.length == state.hiddenLocations.length &&
          hidden.containsAll(state.hiddenLocations);
      if (!same) state = state.copyWith(hiddenLocations: hidden);
    } catch (_) {
      // Non-fatal: a failed check leaves visibility exactly as it was.
    }
  }

  /// Read the persisted library. Called from the shell's post-unlock boot
  /// sequence (the settings store is not open before that), right after the
  /// proxy URL is loaded so relative media paths resolve against the right
  /// base.
  Future<void> loadCached() async {
    try {
      final raw = await storage_api.loadSetting(key: _kLibrarySettingKey);
      if (raw == null || raw.isEmpty) return;
      state = GifLibrary.decode(raw);
      await revalidate();
    } catch (_) {
      // Non-fatal: an unreadable library just starts empty.
    }
  }

  /// Fire-and-forget — losing a recents write is not worth blocking a pick,
  /// and an un-awaited FFI future needs .catchError or it hits the zone
  /// crash handler.
  void _persist() {
    try {
      storage_api
          .saveSetting(key: _kLibrarySettingKey, value: state.encode())
          .catchError((_) {});
    } catch (_) {}
  }

  /// Record a pick. Most-recent first, deduped by id.
  void noteUsed(gifs_api.GifItem item) {
    final saved = SavedGif.fromItem(item, _base);
    if (saved == null) return;
    final recents = [
      saved,
      ...state.recents.where((g) => g.id != saved.id),
    ];
    if (recents.length > _kMaxRecents) recents.removeRange(_kMaxRecents, recents.length);
    // Keep a favourited copy's metadata fresh too (dimensions/paths can
    // change if the proxy re-ingests an item).
    final favorites = state.isFavorite(saved.id)
        ? [
            for (final g in state.favorites) g.id == saved.id ? saved : g,
          ]
        : state.favorites;
    state = state.copyWith(recents: recents, favorites: favorites);
    _persist();
  }

  /// Returns the new favourite state (true = now favourited).
  bool toggleFavorite(gifs_api.GifItem item) {
    final id = item.id;
    if (state.isFavorite(id)) {
      state = state.copyWith(
        favorites: state.favorites.where((g) => g.id != id).toList(),
        // Drop it from every list too, so a re-favourite starts clean.
        collections: [
          for (final c in state.collections)
            c.gifIds.contains(id)
                ? c.copyWith(gifIds: c.gifIds.where((g) => g != id).toList())
                : c,
        ],
      );
      _persist();
      return false;
    }
    final saved = SavedGif.fromItem(item, _base);
    if (saved == null) return false;
    final favorites = [saved, ...state.favorites];
    if (favorites.length > _kMaxFavorites) {
      favorites.removeRange(_kMaxFavorites, favorites.length);
    }
    state = state.copyWith(favorites: favorites);
    _persist();
    return true;
  }

  void removeRecent(String id) {
    state = state.copyWith(
        recents: state.recents.where((g) => g.id != id).toList());
    _persist();
  }

  void clearRecents() {
    state = state.copyWith(recents: const []);
    _persist();
  }

  /// Null when the name is empty or the cap is reached.
  String? createCollection(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || state.collections.length >= _kMaxCollections) {
      return null;
    }
    final clipped = trimmed.length > kMaxGifListNameLength
        ? trimmed.substring(0, kMaxGifListNameLength)
        : trimmed;
    // Monotonic + collision-proof without pulling in a uuid dependency: the
    // set of existing ids is tiny and fully known here.
    var n = state.collections.length + 1;
    var id = 'l$n';
    while (state.collections.any((c) => c.id == id)) {
      id = 'l${++n}';
    }
    state = state.copyWith(collections: [
      ...state.collections,
      GifCollection(id: id, name: clipped, gifIds: const []),
    ]);
    _persist();
    return id;
  }

  void deleteCollection(String id) {
    state = state.copyWith(
        collections: state.collections.where((c) => c.id != id).toList());
    _persist();
  }

  void renameCollection(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final clipped = trimmed.length > kMaxGifListNameLength
        ? trimmed.substring(0, kMaxGifListNameLength)
        : trimmed;
    state = state.copyWith(collections: [
      for (final c in state.collections)
        c.id == id ? c.copyWith(name: clipped) : c,
    ]);
    _persist();
  }

  /// Add/remove a favourite from a list. A GIF must be favourited first —
  /// lists sort favourites, they are not a second store.
  void setInCollection(String collectionId, String gifId, bool member) {
    if (member && !state.isFavorite(gifId)) return;
    state = state.copyWith(collections: [
      for (final c in state.collections)
        if (c.id != collectionId)
          c
        else if (member)
          (c.gifIds.contains(gifId)
              ? c
              : c.copyWith(gifIds: [...c.gifIds, gifId]))
        else
          c.copyWith(gifIds: c.gifIds.where((g) => g != gifId).toList()),
    ]);
    _persist();
  }
}

final gifLibraryProvider =
    NotifierProvider<GifLibraryNotifier, GifLibrary>(GifLibraryNotifier.new);

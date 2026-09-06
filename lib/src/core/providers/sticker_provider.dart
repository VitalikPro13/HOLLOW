import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/gifs.dart' as gifs_api;
import '../../rust/api/stickers.dart' as stickers_api;
import '../../rust/api/storage.dart' as storage_api;
import 'gif_provider.dart';

/// Sticker state: the personal vault, a server's replicated set, and the KLIPY
/// sticker catalog. Bytes are NOT here: a sticker's image rides the same
/// content-addressed rail as emotes and GIFs. Everything below is metadata.

/// The user's personal sticker vault, pack-major and in upload order.
final personalStickersProvider =
    FutureProvider<List<stickers_api.PersonalSticker>>((ref) async {
  try {
    return await stickers_api.listPersonalStickers();
  } catch (_) {
    return const [];
  }
});

/// A server's sticker set (CRDT-replicated metadata), invalidated on `ServerUpdated`.
final serverStickersProvider =
    FutureProvider.family<List<stickers_api.ServerSticker>, String>(
        (ref, serverId) async {
  try {
    return await stickers_api.getServerStickers(serverId: serverId);
  } catch (_) {
    return const [];
  }
});

/// Authoring caps, read from Rust rather than mirrored: `[per server, per
/// pack, packs, vault total, label chars]`.
final stickerLimitsProvider = Provider<StickerLimits>((ref) {
  try {
    final l = stickers_api.stickerLimits();
    return StickerLimits(
      perServer: l[0],
      perPack: l[1],
      packs: l[2],
      vaultTotal: l[3],
      labelChars: l[4],
    );
  } catch (_) {
    // Pre-bridge-init (widget tests): shapes the UI, never a security bound
    // — Rust refuses anything over the real limits regardless.
    return const StickerLimits(
      perServer: 50,
      perPack: 120,
      packs: 50,
      vaultTotal: 600,
      labelChars: 32,
    );
  }
});

@immutable
class StickerLimits {
  final int perServer;
  final int perPack;
  final int packs;
  final int vaultTotal;
  final int labelChars;

  const StickerLimits({
    required this.perServer,
    required this.perPack,
    required this.packs,
    required this.vaultTotal,
    required this.labelChars,
  });
}

/// Session RAM cache over the KLIPY sticker FFI, the GIF catalog's twin.
///
/// Subclassing [GifCatalog] rather than copying is deliberate: its class body
/// holds the wrapper whose `whenComplete` BLOCK body is load-bearing.
class StickerCatalog extends GifCatalog {
  @override
  Future<gifs_api.GifPage> fetchPage(String query, int page, String rating) =>
      query.isEmpty
          ? stickers_api.stickerTrending(page: page, rating: rating)
          : stickers_api.stickerSearch(
              query: query, page: page, rating: rating);

  @override
  Future<List<String>> fetchCategories() => stickers_api.stickerCategories();
}

final stickerCatalogProvider =
    Provider<StickerCatalog>((ref) => StickerCatalog());

const _kRecentsSettingKey = 'sticker_recents';
const _kMaxStickerRecents = 48;

/// One recently sent sticker: its BYTES are a local content-addressed blob, so
/// unlike the GIF library there is no media URL to store or re-authorize.
@immutable
class RecentSticker {
  final String hash;
  final int w;
  final int h;

  const RecentSticker({required this.hash, required this.w, required this.h});

  Map<String, Object?> toJson() => {'h': hash, 'w': w, 'y': h};

  /// Tolerant per row — one unreadable entry must not take the list with it.
  static RecentSticker? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final hash = raw['h'];
    final w = raw['w'];
    final h = raw['y'];
    if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      return null;
    }
    if (w is! int || h is! int || w < 1 || h < 1 || w > 4096 || h > 4096) {
      return null;
    }
    return RecentSticker(hash: hash, w: w, h: h);
  }

  @override
  bool operator ==(Object other) =>
      other is RecentSticker && other.hash == hash && other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(hash, w, h);
}

/// Recently sent stickers, newest first, persisted in the encrypted settings
/// store (local-only; never CRDT or wire state).
class StickerRecentsNotifier extends Notifier<List<RecentSticker>> {
  @override
  List<RecentSticker> build() => const [];

  /// Called from the shell's post-unlock boot sequence (the store opens there).
  Future<void> loadCached() async {
    try {
      final raw = await storage_api.loadSetting(key: _kRecentsSettingKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      state = decoded
          .map(RecentSticker.fromJson)
          .whereType<RecentSticker>()
          .take(_kMaxStickerRecents)
          .toList();
    } catch (_) {
      // Non-fatal: an unreadable list just starts empty.
    }
  }

  void noteUsed(RecentSticker sticker) {
    final next = [
      sticker,
      ...state.where((s) => s.hash != sticker.hash),
    ];
    if (next.length > _kMaxStickerRecents) {
      next.removeRange(_kMaxStickerRecents, next.length);
    }
    state = next;
    _persist();
  }

  void remove(String hash) {
    state = state.where((s) => s.hash != hash).toList();
    _persist();
  }

  void clear() {
    state = const [];
    _persist();
  }

  /// Fire-and-forget: losing a recents write is not worth blocking a send, and an
  /// un-awaited FFI future needs .catchError or it reaches the zone crash handler.
  void _persist() {
    try {
      storage_api
          .saveSetting(
              key: _kRecentsSettingKey,
              value: jsonEncode(state.map((s) => s.toJson()).toList()))
          .catchError((_) {});
    } catch (_) {}
  }
}

final stickerRecentsProvider =
    NotifierProvider<StickerRecentsNotifier, List<RecentSticker>>(
        StickerRecentsNotifier.new);

const _kLastTabSettingKey = 'sticker_last_tab';

/// The tab the sticker picker was last left on, so it reopens where the user
/// left it. Stored as the enum's bare NAME rather than its index: an index
/// silently re-points the moment the enum gains or reorders a case, and an
/// unknown name reads back as null, which the picker resolves to its default.
class StickerLastTabNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Called from the shell's post-unlock boot sequence, alongside recents.
  Future<void> loadCached() async {
    try {
      final raw = await storage_api.loadSetting(key: _kLastTabSettingKey);
      if (raw == null || raw.isEmpty) return;
      state = raw;
    } catch (_) {
      // Non-fatal: an unreadable value just falls back to the default tab.
    }
  }

  void noteTab(String name) {
    if (state == name) return;
    state = name;
    // Fire-and-forget, same as recents: an un-awaited FFI future needs
    // .catchError or the rejection reaches the zone crash handler.
    try {
      storage_api
          .saveSetting(key: _kLastTabSettingKey, value: name)
          .catchError((_) {});
    } catch (_) {}
  }
}

final stickerLastTabProvider =
    NotifierProvider<StickerLastTabNotifier, String?>(
        StickerLastTabNotifier.new);

const _kDeclaredPacksKey = 'sticker_packs';
const _kMaxDeclaredPacks = 50; // matches MAX_PERSONAL_PACKS in Rust

/// Pack names the user has CREATED, whether or not any sticker sits in one yet.
///
/// A pack is a column on `personal_stickers`, so Rust only knows the packs with
/// rows, making "create a pack, then fill it" impossible to express there. This
/// is the local list, unioned with row-derived packs at render time.
class StickerPacksNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  /// Called from the shell's post-unlock boot sequence.
  Future<void> loadCached() async {
    try {
      final raw = await storage_api.loadSetting(key: _kDeclaredPacksKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      state = decoded
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .take(_kMaxDeclaredPacks)
          .toList();
    } catch (_) {
      // Non-fatal: the packs that have rows still show up.
    }
  }

  /// Returns false when the name is empty or already taken (caller toasts).
  bool declare(String name) {
    final clean = name.trim();
    if (clean.isEmpty || state.length >= _kMaxDeclaredPacks) return false;
    if (state.any((p) => p.toLowerCase() == clean.toLowerCase())) return false;
    state = [...state, clean];
    _persist();
    return true;
  }

  void rename(String from, String to) {
    final clean = to.trim();
    if (clean.isEmpty) return;
    state = [
      for (final p in state)
        if (p == from) clean else p,
    ];
    _persist();
  }

  void forget(String name) {
    state = state.where((p) => p != name).toList();
    _persist();
  }

  /// Fire-and-forget, same as recents: an un-awaited FFI future needs
  /// .catchError or the rejection reaches the zone crash handler.
  void _persist() {
    try {
      storage_api
          .saveSetting(key: _kDeclaredPacksKey, value: jsonEncode(state))
          .catchError((_) {});
    } catch (_) {}
  }
}

final stickerPacksProvider =
    NotifierProvider<StickerPacksNotifier, List<String>>(
        StickerPacksNotifier.new);

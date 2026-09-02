import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/shop.dart' as shop_api;

/// The one place that touches the generated shop FFI, so the catalog, the art
/// and the kept codes have a single Dart-side shape.
///
/// The models come straight back out: `ShopCatalog`, `ShopListing`,
/// `ShopArtist`, `ShopFile` and `KeptRedeemCode` are FFI types, and copying
/// them into app-side twins would only add a place for the two to drift.
export 'package:hollow/src/rust/api/shop.dart'
    show
        KeptRedeemCode,
        ShopArtist,
        ShopCatalog,
        ShopFile,
        ShopListing,
        forgetRedeemCode,
        keepRedeemCode,
        listRedeemCodes,
        shopOrigin;

/// The shop's catalog. Deliberately NOT autoDispose: leaving the tab and
/// coming back is the common move, and a refetch there is a wasted round trip
/// plus a spinner over content the person was just looking at. Refresh is an
/// explicit `ref.invalidate`.
final shopCatalogProvider = FutureProvider<shop_api.ShopCatalog>(
  (ref) => shop_api.fetchShopCatalog(),
);

/// `https://shop.anonlisten.com`, from Rust so the two never disagree.
final shopOriginProvider = FutureProvider<String>((ref) => shop_api.shopOrigin());

/// Preview art already fetched this session, so re-opening the tab paints
/// instantly. RAM only, and deliberately so: shop art is not owned, and
/// nothing that has not been bought may land on disk.
final _artCache = <String, Uint8List>{};

/// How many previews the session cache holds before the oldest is dropped.
/// A wall of cards is ~20 entries; 48 covers scrolling back and forth without
/// letting a long browse grow without bound.
const int _kArtCacheMax = 48;

/// Hash-verified preview bytes for one listing's art.
final shopArtProvider =
    FutureProvider.family<Uint8List, String>((ref, hash) async {
  final cached = _artCache[hash];
  if (cached != null) return cached;
  final bytes = await shop_api.fetchShopArt(hash: hash);
  _artCache[hash] = bytes;
  // Insertion-ordered map: the first key is the oldest fetch.
  while (_artCache.length > _kArtCacheMax) {
    _artCache.remove(_artCache.keys.first);
  }
  return bytes;
});

/// Codes kept for later, newest first. Empty is the normal state.
///
/// autoDispose so the list is re-read whenever the panel comes back: a code
/// can arrive from a deep link while nothing is watching this.
final keptRedeemCodesProvider =
    FutureProvider.autoDispose<List<shop_api.KeptRedeemCode>>(
  (ref) => shop_api.listRedeemCodes(),
);

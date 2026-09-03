import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Support marks (design 5.5, 5.6; amended by Vitalik 2026-09-02): the support
/// credentials a profile carries, shown as a BADGE.
///
/// The credentials themselves were verified in Rust before they reached the
/// database (`support_creds::sanitize_incoming_support_creds` for a peer, the
/// redeem path for ourselves), so nothing here checks a signature. What this
/// decides is display only. A credential is a receipt for bought art, and it
/// shows whether or not that art is worn right now: taking a frame off does
/// not un-buy it. The first draft lit a mark only beside worn art; that rule
/// is gone.

/// One credential as the profile field carries it, reduced to what a mark
/// needs.
@immutable
class SupportCred {
  /// The listing's item hash.
  final String item;

  /// The file hashes it vouches for.
  final Set<String> parts;

  /// The HOLDER chose to show this mark next to their name too.
  final bool badge;

  const SupportCred({
    required this.item,
    required this.parts,
    required this.badge,
  });
}

/// What a credential is for, as far as this install can tell.
@immutable
class SupportCredInfo {
  final SupportCred cred;

  /// The artist's display name, or null when nothing here names them.
  final String? artist;

  /// The piece's title, or null.
  final String? title;

  const SupportCredInfo({required this.cred, this.artist, this.title});
}

final _kHex64 = RegExp(r'^[0-9a-f]{64}$');

/// Parse a stored `support_creds` field tolerantly. Anything that is not an
/// array of well-formed entries is no credentials at all.
List<SupportCred> parseSupportCreds(String json) {
  if (json.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final out = <SupportCred>[];
  for (final raw in decoded) {
    if (raw is! Map) continue;
    final t = raw['t'];
    final item = raw['item'];
    final parts = raw['parts'];
    if (t != 1 || item is! String || !_kHex64.hasMatch(item)) continue;
    if (parts is! List) continue;
    final hashes = <String>{
      for (final p in parts)
        if (p is String && _kHex64.hasMatch(p)) p,
    };
    if (hashes.isEmpty) continue;
    out.add(SupportCred(
      item: item,
      parts: hashes,
      badge: raw['badge'] == true,
    ));
  }
  return out;
}

/// The credentials on a profile, parsed once per field VALUE: the field is a
/// string, so the same string parses to the same list and the cache is by
/// content.
final Map<String, List<SupportCred>> _parsed = {};

List<SupportCred> supportCredsOf(storage_api.UserProfile? profile) {
  final json = profile?.supportCreds ?? '';
  if (json.isEmpty) return const [];
  final cached = _parsed[json];
  if (cached != null) return cached;
  final parsed = parseSupportCreds(json);
  // A handful of profiles carry credentials; keep the cache bounded anyway.
  if (_parsed.length > 512) _parsed.clear();
  _parsed[json] = parsed;
  return parsed;
}

/// The credentials [peerId]'s profile carries, every one of them a mark.
final supportMarksProvider =
    Provider.family<List<SupportCred>, String>((ref, peerId) {
  final profile = ref.watch(profileProvider.select((p) => p[peerId]));
  return supportCredsOf(profile);
});

/// Whether [peerId]'s name carries the glyph: at least one credential whose
/// holder left the badge on. Selected as a bool so a chat row never rebuilds
/// for anything but a flip.
final supportBadgeVisibleProvider = Provider.family<bool, String>((ref, peerId) {
  return ref.watch(supportMarksProvider(peerId)).any((cred) => cred.badge);
});

// ── The verified Twitch account ───────────────────────────────────────
//
// The purple chip draws from a `t = 3` credential on the same field and from
// nothing else. `twitch_username` is still on the wire for old clients, but a
// self-declared handle is a claim anybody's modified client can make, so no
// new client renders one (Vitalik, 2026-09-03: no "claims to be" chip).
//
// Nothing here verifies a signature, and nothing here needs to: Rust checked
// the whole chain against the pinned root before the row was written
// (`support_creds::sanitize_incoming_support_creds` for a peer, the verify
// path for ourselves). What is checked is the SHAPE, so a malformed local row
// renders nothing rather than junk, and the WINDOW, so a credential that has
// aged out stops showing here the moment it expires instead of at whatever
// point its holder next announces.

final _kTwitchLogin = RegExp(r'^[a-z0-9_]{4,25}$');

/// The 90-day window a credential is minted for, matching
/// `support_creds::now_period` in Rust.
int _nowPeriod() =>
    DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 ~/ 86400 ~/ 90;

/// The verified Twitch login in a raw `support_creds` field, or null.
String? verifiedTwitchLogin(String json) {
  if (json.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } catch (_) {
    return null;
  }
  if (decoded is! List) return null;
  final now = _nowPeriod();
  for (final raw in decoded) {
    if (raw is! Map) continue;
    if (raw['t'] != 3) continue;
    final period = raw['period'];
    // The current window or the one before it: the same grace Rust gives.
    if (period is! int || period == 0 || (period != now && period + 1 != now)) {
      continue;
    }
    final parts = raw['parts'];
    if (parts is! List || parts.length != 2) continue;
    final login = parts[1];
    if (login is! String || !_kTwitchLogin.hasMatch(login)) continue;
    return login;
  }
  return null;
}

/// Parsed once per field VALUE, like [supportCredsOf]: the field is a string,
/// so the same string always answers the same login.
final Map<String, String?> _twitchLogins = {};

String? twitchLoginOf(storage_api.UserProfile? profile) {
  final json = profile?.supportCreds ?? '';
  if (json.isEmpty) return null;
  if (_twitchLogins.containsKey(json)) return _twitchLogins[json];
  final login = verifiedTwitchLogin(json);
  if (_twitchLogins.length > 512) _twitchLogins.clear();
  _twitchLogins[json] = login;
  return login;
}

/// [peerId]'s VERIFIED Twitch login, or null when there is none.
///
/// The one source for the purple chip on every surface.
final twitchLoginProvider = Provider.family<String?, String>((ref, peerId) {
  final profile = ref.watch(profileProvider.select((p) => p[peerId]));
  return twitchLoginOf(profile);
});

/// [supportMarksProvider] with names attached, looked up in the order that
/// cannot mislead: our own redeem records first (they name the listing the
/// credential was minted for, by its exact item hash), then the shop's
/// catalog by that same exact hash (when there is a shop here and the catalog
/// has been fetched), then our library by an EXACT match of the file set.
/// A looser match came last and lied: a bundle's pack carries the same
/// avatar file as the single avatar's credential, so "any shared hash" named
/// the bundle for both. When only a shared file is known, only the artist is
/// taken from it, never the title. Store builds never fetch the catalog for
/// this (section 8: no shop surface, marks still render).
final supportMarkInfosProvider =
    Provider.family<List<SupportCredInfo>, String>((ref, peerId) {
  final creds = ref.watch(supportMarksProvider(peerId));
  if (creds.isEmpty) return const [];
  final own = ref.watch(shop.ownSupportCredsProvider).valueOrNull ?? const [];
  final owned = ref.watch(ownedArtProvider);
  final shopHere = ref.watch(shopAvailableProvider);
  final catalog =
      shopHere ? ref.watch(shop.shopCatalogProvider).valueOrNull : null;
  return [
    for (final cred in creds) _describe(cred, own, owned, catalog),
  ];
});

SupportCredInfo _describe(
  SupportCred cred,
  List<shop.OwnSupportCred> own,
  List<OwnedItem> owned,
  shop.ShopCatalog? catalog,
) {
  String? clean(String s) => s.isEmpty ? null : s;
  for (final mine in own) {
    if (mine.item == cred.item) {
      return SupportCredInfo(
        cred: cred,
        artist: clean(mine.artistName),
        title: clean(mine.title),
      );
    }
  }
  if (catalog != null) {
    for (final listing in catalog.listings) {
      if (listing.credentialItem == cred.item) {
        return SupportCredInfo(
          cred: cred,
          artist: clean(listing.artist.displayName),
          title: clean(listing.title),
        );
      }
    }
  }
  for (final item in owned) {
    final hashes = item.hashes.toSet();
    if (hashes.length == cred.parts.length && hashes.containsAll(cred.parts)) {
      return SupportCredInfo(
        cred: cred,
        artist: clean(item.artistName),
        title: clean(item.title),
      );
    }
  }
  for (final item in owned) {
    if (item.hashes.any(cred.parts.contains)) {
      return SupportCredInfo(cred: cred, artist: clean(item.artistName));
    }
  }
  return SupportCredInfo(cred: cred);
}

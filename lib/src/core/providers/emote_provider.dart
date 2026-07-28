import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../rust/api/emotes.dart' as emotes_api;

/// Custom emote state: hash-keyed image bytes, server emote sets, and the
/// user's personal (global) set.
///
/// Bytes are content-addressed and pulled on demand: a missing hash triggers
/// ONE `requestEmotes` per session (Rust throttles per-connection too), and
/// `EmoteAssetsReceived` invalidates [emoteBytesProvider] so pending tokens
/// re-render. Receivers never fetch emote images over HTTP.

/// Cached emote bytes for a content hash. `null` = not cached locally (yet).
final emoteBytesProvider =
    FutureProvider.family<Uint8List?, String>((ref, hash) async {
  try {
    return await emotes_api.getEmoteBytes(hash: hash);
  } catch (_) {
    return null;
  }
});

/// A server's custom emote set (CRDT-replicated metadata).
/// Invalidated on `ServerUpdated`.
final serverEmotesProvider =
    FutureProvider.family<List<emotes_api.ServerEmote>, String>(
        (ref, serverId) async {
  try {
    return await emotes_api.getServerEmotes(serverId: serverId);
  } catch (_) {
    return const [];
  }
});

/// The user's personal (global) emote set — usable in every DM and server.
final personalEmotesProvider =
    FutureProvider<List<emotes_api.PersonalEmote>>((ref) async {
  try {
    return await emotes_api.listPersonalEmotes();
  } catch (_) {
    return const [];
  }
});

/// Hashes already requested from the network this session (Dart-side
/// debounce — every rendered unknown token would otherwise cross FFI on
/// each rebuild).
final _requestedHashes = <String>{};

/// Pull emote bytes for [hash] from the network, once per session.
/// `serverId` asks an online member of that server; `peerHint` asks a DM
/// sender's devices. Results arrive via `EmoteAssetsReceived`.
void requestEmoteOnce(String hash, {String? serverId, String? peerHint}) {
  if (_requestedHashes.contains(hash)) return;
  _requestedHashes.add(hash);
  // try/catch AND catchError: a not-yet-running node throws SYNCHRONOUSLY
  // (before a Future exists), which .catchError alone can't intercept.
  try {
    emotes_api
        .requestEmotes(hashes: [hash], serverId: serverId, peerHint: peerHint)
        .catchError((_) {});
  } catch (_) {}
}

/// Pull asset bytes (sticker/GIF/banner) for [hash] from the network, once
/// per session. [kind] is the db kind string (`sticker` | `gif` | `banner`)
/// — it sizes the per-blob cap Rust enforces on receipt. Same rail and same
/// [emoteBytesProvider] cache as emotes (blobs are content-addressed).
void requestAssetOnce(String hash,
    {required String kind, String? serverId, String? peerHint}) {
  if (_requestedHashes.contains(hash)) return;
  _requestedHashes.add(hash);
  // try/catch AND catchError — see requestEmoteOnce.
  try {
    emotes_api
        .requestAssets(
            hashes: [hash], kind: kind, serverId: serverId, peerHint: peerHint)
        .catchError((_) {});
  } catch (_) {}
}

/// Allow a re-pull after new bytes arrive elsewhere or on reconnect-driven
/// invalidation (called from the event stream when assets land, so a hash
/// that failed once isn't locked out forever).
void clearRequestedEmotes(Iterable<String> hashes) {
  for (final h in hashes) {
    _requestedHashes.remove(h);
  }
}

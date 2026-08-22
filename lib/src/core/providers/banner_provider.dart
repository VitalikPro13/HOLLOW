import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// The instance last handed out per peer, so an unchanged banner keeps its
/// IDENTITY across reloads.
final _lastBanner = <String, Uint8List>{};

/// Returns [fresh] unless it is byte-identical to what we last returned for
/// [key], in which case the PREVIOUS instance is handed back.
///
/// This is not a micro-optimisation, it is the fix for a visible bug.
/// [AnimatedGifImage] re-decodes on `!identical(old.bytes, widget.bytes)` —
/// it cannot afford to compare megabytes on every rebuild — so any provider
/// that reloads and returns a fresh-but-equal list makes every animated
/// surface throw away its decoded frames and decode again from scratch.
///
/// Saving a profile does exactly that: `ProfileUpdated` invalidates the
/// avatar and banner providers even when neither changed, and a 1.1 MB
/// animated banner then took long enough to re-decode that the settings
/// preview sat on its gradient placeholder for seconds and looked like the
/// banner had been wiped by the save.
///
/// [ServerAvatarAnimNotifier] already carries this rule for animated server
/// icons ("same hash = same bytes: skip the state write"); those have a hash
/// to compare, these have to compare content.
Uint8List reuseIfUnchanged(
  Map<String, Uint8List> cache,
  String key,
  Uint8List fresh,
) {
  final prev = cache[key];
  if (prev != null &&
      prev.length == fresh.length &&
      // Length first: the common "nothing changed" case is a cheap memcmp,
      // and a differing length short-circuits before touching the bytes.
      listEquals(prev, fresh)) {
    return prev;
  }
  cache[key] = fresh;
  return fresh;
}

/// Lazy banner provider: loads banner bytes on-demand per peer.
///
/// Reloads keep the previous instance when the bytes are unchanged — see
/// [reuseIfUnchanged], which is what stops a profile save blanking the
/// banner while a megabyte of GIF re-decodes.
final bannerProvider =
    FutureProvider.family<Uint8List?, String>((ref, peerId) async {
  final bytes = await storage_api.getBanner(peerId: peerId);
  if (bytes == null || bytes.isEmpty) {
    _lastBanner.remove(peerId);
    return bytes;
  }
  return reuseIfUnchanged(_lastBanner, peerId, bytes);
});

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// The instance last handed out per peer, so an unchanged banner keeps its
/// IDENTITY across reloads.
final _lastBanner = <String, Uint8List>{};

/// Returns [fresh] unless it is byte-identical to what we last returned for
/// [key], in which case the PREVIOUS instance is handed back.
///
/// Not a micro-optimisation: [AnimatedGifImage] re-decodes on
/// `!identical(old.bytes, widget.bytes)`, so a provider that reloads and
/// returns a fresh-but-equal list makes every animated surface throw away its
/// decoded frames. Saving a profile invalidates avatar and banner providers
/// even when neither changed, and a 1.1 MB animated banner then re-decoded
/// long enough to look like the save had wiped it.
Uint8List reuseIfUnchanged(
  Map<String, Uint8List> cache,
  String key,
  Uint8List fresh,
) {
  final prev = cache[key];
  if (prev != null &&
      prev.length == fresh.length &&
      // Length first: a differing length short-circuits before touching the bytes.
      listEquals(prev, fresh)) {
    return prev;
  }
  cache[key] = fresh;
  return fresh;
}

/// Lazy banner provider: loads banner bytes on-demand per peer. Reloads keep
/// the previous instance when the bytes are unchanged (see [reuseIfUnchanged]),
/// which is what stops a profile save blanking the banner mid re-decode.
final bannerProvider =
    FutureProvider.family<Uint8List?, String>((ref, peerId) async {
  final bytes = await storage_api.getBanner(peerId: peerId);
  if (bytes == null || bytes.isEmpty) {
    _lastBanner.remove(peerId);
    return bytes;
  }
  return reuseIfUnchanged(_lastBanner, peerId, bytes);
});

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/emotes.dart' as emotes_api;

import 'emote_provider.dart' show clearRequestedEmotes, requestAssetOnce;

/// Avatar-frame art (issue #54), keyed by FRAME ID.
///
/// A profile carries only the ID; the art rides the content-addressed asset
/// rail, pulled on demand and LRU-evicted under the Storage Manager cap:
/// decoration must be evicted first, never inflate every profile push.
/// Built-in frames (`b:<hue>`) are procedural and never reach this cache.
class AvatarFrameNotifier extends Notifier<Map<String, Uint8List>> {
  /// Hashes read from disk or in flight, so a rebuild storm can't re-ask.
  final _loading = <String>{};

  /// Hash -> the peer we asked for it, for hashes we don't hold yet. The rail
  /// asks ONCE per session, so a fresh profile announce from that peer (what a
  /// reconnect produces) is the signal to try again.
  final _awaiting = <String, String>{};

  @override
  Map<String, Uint8List> build() => {};

  /// Load [id]'s art, pulling it from [peerHint]'s devices when we have no
  /// copy. Safe to call from build (it defers the FFI).
  void ensure(String id, {String? peerHint}) {
    if (!isFrameHash(id) ||
        state.containsKey(id) ||
        _loading.contains(id) ||
        // Already asked and still waiting: without this every rebuild of every
        // framed avatar we don't hold fires a fresh SQLCipher query across the FFI.
        _awaiting.containsKey(id)) {
      return;
    }
    _loading.add(id);
    Future.microtask(() => _load(id, peerHint));
  }

  Future<void> _load(String id, String? peerHint) async {
    try {
      final bytes = await emotes_api.getEmoteBytes(hash: id);
      if (bytes != null && bytes.isNotEmpty) {
        _awaiting.remove(id);
        state = {...state, id: bytes};
        return;
      }
      if (peerHint != null && peerHint.isNotEmpty) {
        _awaiting[id] = peerHint;
        requestAssetOnce(id, kind: 'frame', peerHint: peerHint);
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load avatar frame $id: $e');
    } finally {
      _loading.remove(id);
    }
  }

  /// Put art we just authored straight into the cache, so the picker and the
  /// settings preview paint it without a round trip back through the store.
  void seed(String id, Uint8List bytes) {
    _awaiting.remove(id);
    state = {...state, id: bytes};
  }

  /// Asset bytes landed — re-read anything of ours they cover.
  void onAssetsReceived(Iterable<String> hashes) {
    for (final hash in hashes) {
      if (_awaiting.containsKey(hash)) {
        _awaiting.remove(hash);
        _loading.remove(hash);
        Future.microtask(() => _load(hash, null));
      }
    }
  }

  /// A peer re-announced: retry any frame of theirs we asked for and never got.
  void onProfileUpdated(String peerId) {
    final retry = _awaiting.entries
        .where((e) => e.value == peerId)
        .map((e) => e.key)
        .toList();
    if (retry.isEmpty) return;
    clearRequestedEmotes(retry);
    for (final hash in retry) {
      _loading.remove(hash);
      Future.microtask(() => _load(hash, peerId));
    }
  }
}

final avatarFrameProvider =
    NotifierProvider<AvatarFrameNotifier, Map<String, Uint8List>>(
  AvatarFrameNotifier.new,
);

final _kFrameHash = RegExp(r'^[0-9a-f]{64}$');

/// Whether [id] names art on the asset rail (rather than a built-in).
bool isFrameHash(String id) => id.length == 64 && _kFrameHash.hasMatch(id);

/// The hue of a built-in `b:<hue>` frame, or null if [id] isn't one.
/// Mirrors `node::social::valid_avatar_frame_id` — keep the two in step.
double? builtinFrameHue(String id) {
  if (!id.startsWith('b:')) return null;
  final raw = id.substring(2);
  if (raw.isEmpty || raw.length > 3 || (raw.length > 1 && raw[0] == '0')) {
    return null;
  }
  final hue = int.tryParse(raw);
  if (hue == null || hue < 0 || hue > 359) return null;
  return hue.toDouble();
}

/// Whether [id] is a frame we know how to render at all.
bool isRenderableFrame(String id) =>
    id.isNotEmpty && (isFrameHash(id) || builtinFrameHue(id) != null);

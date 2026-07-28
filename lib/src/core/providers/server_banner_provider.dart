import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

import 'emote_provider.dart' show requestAssetOnce;

/// One server's banner as held locally. [hash] keys crossfades (a re-upload
/// changes it even though the server label doesn't); [animated] mirrors the
/// `server_banner_animated` CRDT setting.
class ServerBannerEntry {
  final Uint8List bytes;
  final String hash;
  final bool animated;

  const ServerBannerEntry({
    required this.bytes,
    required this.hash,
    required this.animated,
  });
}

/// Cache of server banner bytes keyed by server_id. Near-copy of
/// [ServerAvatarNotifier], plus the asset-rail pull: the CRDT carries only
/// the banner HASH — when the blob isn't cached yet we request it once via
/// `request_assets(kind: banner)` and reload when `EmoteAssetsReceived`
/// delivers it (see `onAssetsReceived`, wired in event_provider).
class ServerBannerNotifier extends Notifier<Map<String, ServerBannerEntry>> {
  // Local-write bookkeeping: `set_server_banner`/`clear_server_banner` only
  // QUEUE a node command — the CRDT apply + CrdtStore persist land later, so
  // a DB read right after the FFI returns the PREVIOUS banner. Same pattern
  // (and same "second upload applies the first icon" bug) as avatars.
  final Map<String, int> _writeGen = {};
  final Set<String> _writePending = {};

  // hash -> server_id for banners whose blob is still in flight on the
  // asset rail, so EmoteAssetsReceived knows which server to reload.
  final Map<String, String> _pendingPulls = {};

  @override
  Map<String, ServerBannerEntry> build() => {};

  Future<void> loadBanner(String serverId) async {
    if (_writePending.contains(serverId)) return;
    await _loadFromDb(serverId);
  }

  Future<void> _loadFromDb(String serverId) async {
    try {
      final data = await crdt_api.getServerBanner(serverId: serverId);
      if (data == null) {
        if (state.containsKey(serverId)) {
          final next = Map<String, ServerBannerEntry>.from(state);
          next.remove(serverId);
          state = next;
        }
        return;
      }
      final bytes = data.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        _pendingPulls.remove(data.hash);
        // Same hash = same content-addressed bytes: skip the state write so
        // ServerUpdated churn doesn't hand AnimatedGifImage a fresh bytes
        // instance (it re-decodes and restarts on !identical bytes).
        final existing = state[serverId];
        if (existing != null && existing.hash == data.hash) return;
        state = {
          ...state,
          serverId: ServerBannerEntry(
            bytes: bytes,
            hash: data.hash,
            animated: data.animated,
          ),
        };
      } else {
        // Hash replicated but the blob hasn't been pulled yet — ask one
        // online member of this server's room. Any previous banner stays
        // rendered until the new bytes land (no flash to empty).
        _pendingPulls[data.hash] = serverId;
        requestAssetOnce(data.hash, kind: 'banner', serverId: serverId);
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load server banner for $serverId: $e');
    }
  }

  /// Called from the event stream when asset bytes arrive; reloads any
  /// server whose banner pull just completed.
  void onAssetsReceived(Iterable<String> hashes) {
    for (final hash in hashes) {
      final serverId = _pendingPulls.remove(hash);
      if (serverId != null) {
        loadBanner(serverId);
      }
    }
  }

  Future<void> applyLocalWrite(String serverId, Uint8List? optimistic) async {
    final gen = (_writeGen[serverId] ?? 0) + 1;
    _writeGen[serverId] = gen;
    _writePending.add(serverId);
    if (optimistic != null) {
      // Hash is unknown until the Rust processing lands; the reload below
      // replaces this placeholder entry with the real one.
      state = {
        ...state,
        serverId: ServerBannerEntry(
          bytes: optimistic,
          hash: '',
          animated: false,
        ),
      };
    } else if (state.containsKey(serverId)) {
      final next = Map<String, ServerBannerEntry>.from(state);
      next.remove(serverId);
      state = next;
    }
    await Future.delayed(const Duration(milliseconds: 1200));
    if (_writeGen[serverId] != gen) return; // superseded by a newer write
    _writePending.remove(serverId);
    await _loadFromDb(serverId);
  }

  Future<void> loadAll(List<String> serverIds) async {
    for (final id in serverIds) {
      await loadBanner(id);
    }
  }
}

final serverBannerProvider =
    NotifierProvider<ServerBannerNotifier, Map<String, ServerBannerEntry>>(
  ServerBannerNotifier.new,
);

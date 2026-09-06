import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

import 'emote_provider.dart' show requestAssetOnce;

/// One server's ANIMATED icon as held locally; the still icon lives in
/// [serverAvatarProvider] (base64 inside the CRDT). [hash] keys re-decodes, so
/// a re-upload changes it even though the server doesn't.
class ServerAvatarAnimEntry {
  final Uint8List bytes;
  final String hash;

  const ServerAvatarAnimEntry({required this.bytes, required this.hash});
}

/// Cache of animated server-icon bytes keyed by server_id. The CRDT carries
/// only the HASH in `settings["server_avatar_anim"]`; when the blob isn't
/// cached we request it once via `request_assets(kind: avatar)` and reload
/// when `EmoteAssetsReceived` delivers it.
class ServerAvatarAnimNotifier extends Notifier<Map<String, ServerAvatarAnimEntry>> {
  // `set_server_avatar`/`clear_server_avatar` only QUEUE a node command, so a
  // DB read right after the FFI returns the PREVIOUS icon: the same "second
  // upload applies the first icon" bug as avatars.
  final Map<String, int> _writeGen = {};
  final Set<String> _writePending = {};

  // hash -> server_id for icons whose blob is still in flight on the
  // asset rail, so EmoteAssetsReceived knows which server to reload.
  final Map<String, String> _pendingPulls = {};

  @override
  Map<String, ServerAvatarAnimEntry> build() => {};

  Future<void> loadAnim(String serverId) async {
    if (_writePending.contains(serverId)) return;
    await _loadFromDb(serverId);
  }

  Future<void> _loadFromDb(String serverId) async {
    try {
      final data = await crdt_api.getServerAvatarAnim(serverId: serverId);
      if (data == null) {
        if (state.containsKey(serverId)) {
          final next = Map<String, ServerAvatarAnimEntry>.from(state);
          next.remove(serverId);
          state = next;
        }
        return;
      }
      final bytes = data.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        _pendingPulls.remove(data.hash);
        // Same hash = same content-addressed bytes: skip the state write, or
        // ServerUpdated churn hands AnimatedGifImage a fresh instance and it re-decodes.
        final existing = state[serverId];
        if (existing != null && existing.hash == data.hash) return;
        state = {
          ...state,
          serverId: ServerAvatarAnimEntry(bytes: bytes, hash: data.hash),
        };
      } else {
        // Hash replicated but the blob isn't pulled yet: ask one online member. The
        // still icon renders until the animated bytes land.
        _pendingPulls[data.hash] = serverId;
        requestAssetOnce(data.hash, kind: 'avatar', serverId: serverId);
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load animated server icon for $serverId: $e');
    }
  }

  /// Called from the event stream when asset bytes arrive; reloads any
  /// server whose animated-icon pull just completed.
  void onAssetsReceived(Iterable<String> hashes) {
    for (final hash in hashes) {
      final serverId = _pendingPulls.remove(hash);
      if (serverId != null) {
        loadAnim(serverId);
      }
    }
  }

  Future<void> applyLocalWrite(String serverId, Uint8List? optimistic) async {
    final gen = (_writeGen[serverId] ?? 0) + 1;
    _writeGen[serverId] = gen;
    _writePending.add(serverId);
    if (optimistic != null) {
      // Hash is unknown until the Rust processing lands; the reload replaces this.
      state = {
        ...state,
        serverId: ServerAvatarAnimEntry(bytes: optimistic, hash: ''),
      };
    } else if (state.containsKey(serverId)) {
      // A still upload (or clear) drops any previous animated icon.
      final next = Map<String, ServerAvatarAnimEntry>.from(state);
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
      await loadAnim(id);
    }
  }
}

final serverAvatarAnimProvider =
    NotifierProvider<ServerAvatarAnimNotifier, Map<String, ServerAvatarAnimEntry>>(
  ServerAvatarAnimNotifier.new,
);

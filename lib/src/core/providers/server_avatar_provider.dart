import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// Cache of server avatar bytes keyed by server_id.
class ServerAvatarNotifier extends Notifier<Map<String, Uint8List>> {
  // `set_server_avatar`/`clear_server_avatar` only QUEUE a node command, so a
  // DB read right after the FFI returns the PREVIOUS avatar. That was the
  // "second upload applies the first icon" bug.
  final Map<String, int> _writeGen = {};
  final Set<String> _writePending = {};

  @override
  Map<String, Uint8List> build() => {};

  /// Load a server avatar from DB and cache it. Skipped while a local write
  /// is pending — the optimistic seed is fresher than anything the DB can
  /// return until the write lands (a stale read here resurrects the old icon).
  Future<void> loadAvatar(String serverId) async {
    if (_writePending.contains(serverId)) return;
    await _loadFromDb(serverId);
  }

  Future<void> _loadFromDb(String serverId) async {
    try {
      final bytes = await crdt_api.getServerAvatar(serverId: serverId);
      if (bytes != null && bytes.isNotEmpty) {
        state = {...state, serverId: bytes};
      } else {
        if (state.containsKey(serverId)) {
          final next = Map<String, Uint8List>.from(state);
          next.remove(serverId);
          state = next;
        }
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load server avatar for $serverId: $e');
    }
  }

  /// Seed the cache for a local avatar write ([optimistic] bytes, or null for a
  /// clear), then reconcile from the DB once the fire-and-forget CRDT persist has
  /// had time to land. Callers fire-and-forget this; it never throws.
  Future<void> applyLocalWrite(String serverId, Uint8List? optimistic) async {
    final gen = (_writeGen[serverId] ?? 0) + 1;
    _writeGen[serverId] = gen;
    _writePending.add(serverId);
    if (optimistic != null) {
      state = {...state, serverId: optimistic};
    } else if (state.containsKey(serverId)) {
      final next = Map<String, Uint8List>.from(state);
      next.remove(serverId);
      state = next;
    }
    await Future.delayed(const Duration(milliseconds: 1200));
    if (_writeGen[serverId] != gen) return; // superseded by a newer write
    _writePending.remove(serverId);
    // Swap the seed for the canonical processed bytes (or confirm the clear).
    await _loadFromDb(serverId);
  }

  /// Load avatars for all servers.
  Future<void> loadAll(List<String> serverIds) async {
    for (final id in serverIds) {
      await loadAvatar(id);
    }
  }
}

final serverAvatarProvider =
    NotifierProvider<ServerAvatarNotifier, Map<String, Uint8List>>(
  ServerAvatarNotifier.new,
);

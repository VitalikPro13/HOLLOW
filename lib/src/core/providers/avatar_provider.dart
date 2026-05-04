import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Lazy avatar cache: peer_id → avatar bytes.
/// Avatars are loaded on-demand when HollowAvatar mounts, not at startup.
class AvatarNotifier extends Notifier<Map<String, Uint8List>> {
  final _loading = <String>{};

  @override
  Map<String, Uint8List> build() => {};

  Future<void> loadAvatar(String peerId) async {
    if (state.containsKey(peerId) || _loading.contains(peerId)) return;
    _loading.add(peerId);
    try {
      final bytes = await storage_api.getAvatar(peerId: peerId);
      if (bytes != null && bytes.isNotEmpty) {
        state = {...state, peerId: bytes};
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load avatar for $peerId: $e');
    } finally {
      _loading.remove(peerId);
    }
  }

  void invalidate(String peerId) {
    if (state.containsKey(peerId)) {
      final next = Map<String, Uint8List>.from(state);
      next.remove(peerId);
      state = next;
    }
    _loading.remove(peerId);
  }
}

final avatarProvider =
    NotifierProvider<AvatarNotifier, Map<String, Uint8List>>(
  AvatarNotifier.new,
);

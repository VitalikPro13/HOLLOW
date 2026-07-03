import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Lazy avatar cache: peer_id → avatar bytes.
/// Avatars are loaded on-demand when HollowAvatar mounts, not at startup.
class AvatarNotifier extends Notifier<Map<String, Uint8List>> {
  final _loading = <String>{};

  /// Negative cache: peers we KNOW have no avatar. Without it every rebuild
  /// of every row showing an avatar-less peer fired a fresh FFI SQLCipher
  /// query. Cleared per-peer by [invalidate] (ProfileUpdated), so a newly
  /// set avatar still comes through.
  final _missing = <String>{};

  @override
  Map<String, Uint8List> build() => {};

  Future<void> loadAvatar(String peerId) async {
    if (state.containsKey(peerId) ||
        _loading.contains(peerId) ||
        _missing.contains(peerId)) {
      return;
    }
    _loading.add(peerId);
    try {
      final bytes = await storage_api.getAvatar(peerId: peerId);
      if (bytes != null && bytes.isNotEmpty) {
        state = {...state, peerId: bytes};
      } else {
        _missing.add(peerId);
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load avatar for $peerId: $e');
    } finally {
      _loading.remove(peerId);
    }
  }

  void setAvatar(String peerId, Uint8List bytes) {
    _missing.remove(peerId);
    state = {...state, peerId: bytes};
  }

  void invalidate(String peerId) {
    if (state.containsKey(peerId)) {
      final next = Map<String, Uint8List>.from(state);
      next.remove(peerId);
      state = next;
    }
    _loading.remove(peerId);
    _missing.remove(peerId);
  }
}

final avatarProvider =
    NotifierProvider<AvatarNotifier, Map<String, Uint8List>>(
  AvatarNotifier.new,
);

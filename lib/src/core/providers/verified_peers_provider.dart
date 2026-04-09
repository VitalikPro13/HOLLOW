import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Set of peer IDs that have been identity-verified (fingerprint confirmed).
class VerifiedPeersNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Load verified peers from the database.
  Future<void> load() async {
    try {
      final pairs = await storage_api.getVerifiedPeers();
      state = pairs.map((p) => p.$1).toSet();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load verified peers: $e');
    }
  }

  /// Mark a peer as verified.
  Future<void> verify(String peerId) async {
    try {
      await storage_api.setPeerVerified(peerId: peerId);
      state = {...state, peerId};
    } catch (e) {
      debugPrint('[HOLLOW] Failed to verify peer: $e');
    }
  }

  /// Remove verified status from a peer.
  Future<void> unverify(String peerId) async {
    try {
      await storage_api.removePeerVerified(peerId: peerId);
      state = state.where((id) => id != peerId).toSet();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to unverify peer: $e');
    }
  }

  bool isVerified(String peerId) => state.contains(peerId);
}

final verifiedPeersProvider =
    NotifierProvider<VerifiedPeersNotifier, Set<String>>(
        VerifiedPeersNotifier.new);

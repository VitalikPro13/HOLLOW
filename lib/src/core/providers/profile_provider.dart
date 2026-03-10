import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:haven/src/rust/api/storage.dart' as storage_api;

/// In-memory profile cache: peer_id → UserProfile.
/// Loaded from DB on startup, updated on ProfileUpdated events.
class ProfileNotifier extends Notifier<Map<String, storage_api.UserProfile>> {
  @override
  Map<String, storage_api.UserProfile> build() => {};

  /// Load all profiles from the local DB into memory.
  Future<void> loadAll() async {
    try {
      final profiles = await storage_api.getAllProfiles();
      final map = <String, storage_api.UserProfile>{};
      for (final p in profiles) {
        map[p.peerId] = p;
      }
      state = map;
    } catch (e) {
      debugPrint('[HAVEN] Failed to load profiles: $e');
    }
  }

  /// Reload a single profile from DB (called on ProfileUpdated event).
  Future<void> reloadProfile(String peerId) async {
    try {
      final profile = await storage_api.getProfile(peerId: peerId);
      if (profile != null) {
        state = {...state, peerId: profile};
      }
    } catch (e) {
      debugPrint('[HAVEN] Failed to reload profile for $peerId: $e');
    }
  }

  /// Update our own profile — sends command to Rust which saves + broadcasts.
  Future<void> updateMyProfile({
    required String displayName,
    String status = '',
    String aboutMe = '',
  }) async {
    try {
      await network_api.updateProfile(
        displayName: displayName,
        status: status,
        aboutMe: aboutMe,
      );
    } catch (e) {
      debugPrint('[HAVEN] Failed to update profile: $e');
    }
  }
}

final profileProvider =
    NotifierProvider<ProfileNotifier, Map<String, storage_api.UserProfile>>(
  ProfileNotifier.new,
);

/// Get a display name for a peer. Falls back to short peer ID.
/// Used in DM context (no nicknames).
String displayNameFor(
  Map<String, storage_api.UserProfile> profiles,
  String peerId,
) {
  final profile = profiles[peerId];
  if (profile != null && profile.displayName.isNotEmpty) {
    return profile.displayName;
  }
  // Fallback: first 8 chars of peer ID.
  return peerId.length > 8 ? '${peerId.substring(0, 8)}...' : peerId;
}

/// Get a display name for a peer in a server context.
/// Resolution order: nickname → profile display name → short peer ID.
String serverDisplayNameFor(
  Map<String, storage_api.UserProfile> profiles,
  String peerId, {
  String nickname = '',
}) {
  if (nickname.isNotEmpty) return nickname;
  return displayNameFor(profiles, peerId);
}

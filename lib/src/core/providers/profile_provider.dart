import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// In-memory profile cache (peer_id -> UserProfile), updated on ProfileUpdated.
class ProfileNotifier extends Notifier<Map<String, storage_api.UserProfile>> {
  @override
  Map<String, storage_api.UserProfile> build() => {};

  /// Load all profiles from the local DB into memory.
  Future<void> loadAll() async {
    try {
      final profiles = await storage_api.getAllProfilesLight();
      final map = <String, storage_api.UserProfile>{};
      for (final p in profiles) {
        map[p.peerId] = p;
      }
      state = map;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load profiles: $e');
    }
  }

  /// Reload a single profile from DB (called on ProfileUpdated event).
  Future<void> reloadProfile(String peerId) async {
    try {
      final profile = await storage_api.getProfileLight(peerId: peerId);
      if (profile != null) {
        state = {...state, peerId: profile};
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to reload profile for $peerId: $e');
    }
  }

  /// Update our own profile: sends a command to Rust, which saves + broadcasts.
  ///
  /// Image and field arguments share one convention: null = no change, empty =
  /// clear, else the new value. avatarFrame takes a built-in `b:<hue>` or the
  /// hash of a stored frame blob (issue #54). avatarAnim/bannerAnim take the
  /// hash from `processAndStoreAvatarAnim`/`processAndStoreBannerAnim` with its
  /// `still` as avatarBytes/bannerBytes; pass `''` for a STILL pick or the
  /// previous animation keeps playing over the new still. supportCreds is
  /// normally null: Rust rebuilds the field from its own table on redeem.
  Future<void> updateMyProfile({
    required String displayName,
    String status = '',
    String aboutMe = '',
    Uint8List? avatarBytes,
    Uint8List? bannerBytes,
    String twitchUsername = '',
    String? showcaseBoard,
    List<showcase_api.ShowcaseAsset>? showcaseAssets,
    String? avatarFrame,
    String? avatarAnim,
    String? bannerAnim,
    String? supportCreds,
  }) async {
    // `updateProfile` resolves once the command is QUEUED on the node's channel:
    // the surfaced failures are a dead node, oversized showcase assets and a
    // channel-send failure. There is no end-to-end broadcast ack to claim.
    try {
      await network_api.updateProfile(
        displayName: displayName,
        status: status,
        aboutMe: aboutMe,
        avatarBytes: avatarBytes,
        bannerBytes: bannerBytes,
        twitchUsername: twitchUsername,
        showcaseBoard: showcaseBoard,
        showcaseAssets: showcaseAssets,
        avatarFrame: avatarFrame,
        avatarAnim: avatarAnim,
        bannerAnim: bannerAnim,
        supportCreds: supportCreds,
      );
    } catch (e) {
      // Rethrow so save UIs show a REAL failure instead of a false success toast.
      debugPrint('[HOLLOW] Failed to update profile: $e');
      rethrow;
    }
  }

  /// Save ONLY the showcase board, carrying the other profile fields through
  /// unchanged. Optimistically patches the cache: the Rust save is
  /// fire-and-forget, so the DB may be stale when the dialog re-reads.
  Future<void> updateShowcaseBoard(
    String peerId,
    String encoded, {
    List<showcase_api.ShowcaseAsset>? assets,
  }) async {
    final current = state[peerId];
    await updateMyProfile(
      displayName: current?.displayName ?? '',
      status: current?.status ?? '',
      aboutMe: current?.aboutMe ?? '',
      twitchUsername: current?.twitchUsername ?? '',
      showcaseBoard: encoded,
      showcaseAssets: assets,
    );
    if (current != null) {
      state = {
        ...state,
        peerId: storage_api.UserProfile(
          peerId: current.peerId,
          displayName: current.displayName,
          status: current.status,
          aboutMe: current.aboutMe,
          updatedAt: current.updatedAt,
          avatarBytes: current.avatarBytes,
          bannerBytes: current.bannerBytes,
          twitchUsername: current.twitchUsername,
          showcaseBoard: encoded,
          avatarFrame: current.avatarFrame,
          avatarAnim: current.avatarAnim,
          bannerAnim: current.bannerAnim,
          supportCreds: current.supportCreds,
        ),
      };
    }
  }

  /// Optimistically patch MY profile's media fields after a save, so every
  /// surface paints the new art without waiting for `ProfileUpdated`.
  ///
  /// `null` leaves a field alone, a value replaces it. The DB is deliberately NOT
  /// read back: the Rust save is fire-and-forget, so a read returns the old value.
  void patchMyMedia({
    String? avatarFrame,
    String? avatarAnim,
    String? bannerAnim,
    Uint8List? avatarBytes,
    Uint8List? bannerBytes,
  }) {
    final peerId = ref.read(identityProvider).peerId ?? '';
    if (peerId.isEmpty) return;
    final current = state[peerId];
    if (current == null) return;
    state = {
      ...state,
      peerId: storage_api.UserProfile(
        peerId: current.peerId,
        displayName: current.displayName,
        status: current.status,
        aboutMe: current.aboutMe,
        updatedAt: current.updatedAt,
        avatarBytes: avatarBytes ?? current.avatarBytes,
        bannerBytes: bannerBytes ?? current.bannerBytes,
        twitchUsername: current.twitchUsername,
        showcaseBoard: current.showcaseBoard,
        avatarFrame: avatarFrame ?? current.avatarFrame,
        avatarAnim: avatarAnim ?? current.avatarAnim,
        bannerAnim: bannerAnim ?? current.bannerAnim,
        supportCreds: current.supportCreds,
      ),
    };
  }
}

final profileProvider =
    NotifierProvider<ProfileNotifier, Map<String, storage_api.UserProfile>>(
  ProfileNotifier.new,
);

/// Static reference to local nicknames, kept in sync by LocalNicknameNotifier.
Map<String, String> _localNicknames = const {};

/// Called from _bootstrap to set the static reference.
void setLocalNicknamesRef(Map<String, String> nicknames) {
  _localNicknames = nicknames;
}

/// Get a display name for a peer. Falls back to short peer ID.
/// Resolution: local nickname → profile display name → short peer ID.
String displayNameFor(
  Map<String, storage_api.UserProfile> profiles,
  String peerId,
) {
  return displayNameForPeer(profiles[peerId], peerId);
}

/// Same as [displayNameFor] but takes a single [UserProfile?] instead of the
/// full map. Prefer this with `ref.watch(profileProvider.select(...))` to
/// avoid rebuilding when unrelated profiles change.
String displayNameForPeer(storage_api.UserProfile? profile, String peerId) {
  final localNick = _localNicknames[peerId];
  if (localNick != null && localNick.isNotEmpty) return localNick;
  if (profile != null && profile.displayName.isNotEmpty) {
    return profile.displayName;
  }
  return peerId.length > 8 ? '${peerId.substring(0, 8)}...' : peerId;
}

/// Get a display name for a peer in a server context.
/// Resolution: server nickname → local nickname → profile display name → short peer ID.
String serverDisplayNameFor(
  Map<String, storage_api.UserProfile> profiles,
  String peerId, {
  String nickname = '',
}) {
  if (nickname.isNotEmpty) return nickname;
  return displayNameForPeer(profiles[peerId], peerId);
}

/// Same as [serverDisplayNameFor] but takes a single [UserProfile?].
String serverDisplayNameForPeer(
  storage_api.UserProfile? profile,
  String peerId, {
  String nickname = '',
}) {
  if (nickname.isNotEmpty) return nickname;
  return displayNameForPeer(profile, peerId);
}

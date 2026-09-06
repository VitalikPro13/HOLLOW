import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/emotes.dart' as emotes_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Shop art this identity has imported, grouped into the ITEM it was sold as.
///
/// The rail stores one row per file (an animated avatar is two), because that
/// is what it replicates. A person bought an ITEM, so that is what "Wear" acts on.
class OwnedItem {
  final String itemId;
  final String title;
  final String artistName;
  final String artistSlug;
  final String artistUrl;
  final String license;

  /// Unix milliseconds of the import.
  final int importedAt;

  /// role -> the row. Roles are `frame`, `avatar`, `avatar_anim`,
  /// `avatar_still`, `banner`, `banner_anim`, `banner_still`.
  final Map<String, network_api.OwnedArt> byRole;

  const OwnedItem({
    required this.itemId,
    required this.title,
    required this.artistName,
    required this.artistSlug,
    required this.artistUrl,
    required this.license,
    required this.importedAt,
    required this.byRole,
  });

  String? get frameHash => byRole['frame']?.hash;

  /// The ANIMATED avatar, which rides the asset rail. Null for a still-only
  /// item, which is most of them.
  String? get avatarAnimHash => byRole['avatar_anim']?.hash;

  /// The STILL avatar, which rides the profile push. A still-only item packs
  /// it as `avatar`; an animated one packs its companion as `avatar_still`.
  String? get avatarStillHash =>
      (byRole['avatar'] ?? byRole['avatar_still'])?.hash;

  String? get bannerAnimHash => byRole['banner_anim']?.hash;

  String? get bannerStillHash =>
      (byRole['banner'] ?? byRole['banner_still'])?.hash;

  /// The wearable kinds this item carries, in a fixed order so two items with
  /// the same contents always read the same way.
  List<String> get kinds => [
        if (frameHash != null) 'frame',
        if (avatarStillHash != null || avatarAnimHash != null) 'avatar',
        if (bannerStillHash != null || bannerAnimHash != null) 'banner',
      ];

  Set<String> get hashes => {for (final art in byRole.values) art.hash};

  bool get bundle => kinds.length >= 2;
}

/// Human wording for a pack role, for the "what was imported" list.
String ownedRoleLabel(String role) {
  switch (role) {
    case 'frame':
      return 'Frame';
    case 'avatar':
    case 'avatar_still':
      return 'Avatar';
    case 'avatar_anim':
      return 'Animated avatar';
    case 'banner':
    case 'banner_still':
      return 'Banner';
    case 'banner_anim':
      return 'Animated banner';
    default:
      return role;
  }
}

/// The label on a "Wear" button for a kind.
String wearKindLabel(String kind) {
  switch (kind) {
    case 'frame':
      return 'Wear frame';
    case 'avatar':
      return 'Wear avatar';
    case 'banner':
      return 'Wear banner';
    default:
      return 'Wear';
  }
}

class OwnedArtNotifier extends Notifier<List<OwnedItem>> {
  bool _scheduled = false;

  @override
  List<OwnedItem> build() {
    // One deferred load per container: a Notifier's build runs again on every
    // dependency change, and this list is only refreshed explicitly.
    if (!_scheduled) {
      _scheduled = true;
      Future.microtask(reload);
    }
    return const [];
  }

  /// Re-read the rail and regroup. Newest import first.
  Future<void> reload() async {
    try {
      final rows = await network_api.listOwnedArt();
      final grouped = <String, Map<String, network_api.OwnedArt>>{};
      final newest = <String, network_api.OwnedArt>{};
      for (final row in rows) {
        (grouped[row.itemId] ??= {})[row.role] = row;
        final seen = newest[row.itemId];
        if (seen == null || row.importedAt.toInt() > seen.importedAt.toInt()) {
          newest[row.itemId] = row;
        }
      }
      final items = <OwnedItem>[
        for (final entry in grouped.entries)
          OwnedItem(
            itemId: entry.key,
            title: newest[entry.key]!.title,
            artistName: newest[entry.key]!.artistName,
            artistSlug: newest[entry.key]!.artistSlug,
            artistUrl: newest[entry.key]!.artistUrl,
            license: newest[entry.key]!.license,
            importedAt: newest[entry.key]!.importedAt.toInt(),
            byRole: entry.value,
          ),
      ]..sort((a, b) => b.importedAt.compareTo(a.importedAt));
      state = items;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to list owned art: $e');
    }
  }

  /// Put [kinds] of [item] on my profile.
  ///
  /// Rethrows so the call site can toast a real failure.
  ///
  /// The still rides the profile push and the animation rides the asset rail, so
  /// a still-only pick sends `''` for the animation hash: null means PRESERVE.
  Future<void> wear(OwnedItem item, Set<String> kinds) async {
    final me = ref.read(identityProvider).peerId ?? '';
    if (me.isEmpty) {
      throw Exception('Your identity is not loaded yet; try again in a moment');
    }
    final current = ref.read(profileProvider)[me];

    String? avatarFrame;
    String? avatarAnim;
    String? bannerAnim;
    Uint8List? avatarBytes;
    Uint8List? bannerBytes;

    if (kinds.contains('frame')) {
      final hash = item.frameHash;
      if (hash == null) {
        throw Exception('This item has no frame to wear');
      }
      avatarFrame = hash;
      final bytes = await emotes_api.getEmoteBytes(hash: hash);
      if (bytes != null && bytes.isNotEmpty) {
        ref.read(avatarFrameProvider.notifier).seed(hash, bytes);
      }
    }

    if (kinds.contains('avatar')) {
      final still = item.avatarStillHash;
      final bytes =
          still == null ? null : await emotes_api.getEmoteBytes(hash: still);
      if (bytes == null || bytes.isEmpty) {
        throw Exception(
            'The avatar for this item is missing; import its pack again');
      }
      avatarBytes = bytes;
      final anim = item.avatarAnimHash;
      avatarAnim = anim ?? '';
      if (anim != null) {
        final animBytes = await emotes_api.getEmoteBytes(hash: anim);
        if (animBytes != null && animBytes.isNotEmpty) {
          ref.read(profileAnimProvider.notifier).seed(anim, animBytes);
        }
      }
    }

    if (kinds.contains('banner')) {
      final still = item.bannerStillHash;
      final bytes =
          still == null ? null : await emotes_api.getEmoteBytes(hash: still);
      if (bytes == null || bytes.isEmpty) {
        throw Exception(
            'The banner for this item is missing; import its pack again');
      }
      bannerBytes = bytes;
      final anim = item.bannerAnimHash;
      bannerAnim = anim ?? '';
      if (anim != null) {
        final animBytes = await emotes_api.getEmoteBytes(hash: anim);
        if (animBytes != null && animBytes.isNotEmpty) {
          ref.read(profileAnimProvider.notifier).seed(anim, animBytes);
        }
      }
    }

    await ref.read(profileProvider.notifier).updateMyProfile(
          // A fresh install has no display name yet; pass whatever is there
          // through unchanged rather than inventing one.
          displayName: current?.displayName ?? '',
          status: current?.status ?? '',
          aboutMe: current?.aboutMe ?? '',
          twitchUsername: current?.twitchUsername ?? '',
          avatarBytes: avatarBytes,
          bannerBytes: bannerBytes,
          avatarFrame: avatarFrame,
          avatarAnim: avatarAnim,
          bannerAnim: bannerAnim,
        );

    // Optimistic: the save is fire-and-forget through the node command channel,
    // so reading the DB back now would return the PREVIOUS value.
    if (avatarBytes != null) {
      ref.read(avatarProvider.notifier).setAvatar(me, avatarBytes);
    }
    ref.read(profileProvider.notifier).patchMyMedia(
          avatarFrame: avatarFrame,
          avatarAnim: avatarAnim,
          bannerAnim: bannerAnim,
          avatarBytes: avatarBytes,
          bannerBytes: bannerBytes,
        );
  }
}

final ownedArtProvider =
    NotifierProvider<OwnedArtNotifier, List<OwnedItem>>(OwnedArtNotifier.new);

/// Every hash in this identity's library. Decides Wear it, never Owned:
/// a pack can be handed over, a credential cannot (see
/// `ownCredentialItemsProvider`).
final ownedHashesProvider = Provider<Set<String>>((ref) {
  final items = ref.watch(ownedArtProvider);
  return {for (final item in items) ...item.hashes};
});

/// Rail bytes by hash, for a thumbnail. Kind-agnostic: the rail is one blob
/// store, and a frame, an avatar and a banner all come out of it by hash.
final railBytesProvider =
    FutureProvider.family<Uint8List?, String>((ref, hash) async {
  if (hash.isEmpty) return null;
  return emotes_api.getEmoteBytes(hash: hash);
});

final _kHex64 = RegExp(r'^[0-9a-f]{64}$');

/// sha256 per BYTES INSTANCE (shared with the support marks), so a rebuild
/// never re-hashes a megabyte of banner. The providers hand back the SAME
/// instance when nothing changed, which is what makes this sound.
final Expando<String> _digestOfInstance = Expando<String>('sha256');

String digestOfBytes(Uint8List bytes) {
  final cached = _digestOfInstance[bytes];
  if (cached != null) return cached;
  final value = crypto.sha256.convert(bytes).toString();
  _digestOfInstance[bytes] = value;
  return value;
}

/// The hashes MY profile is currently wearing, so a row can read "Worn".
///
/// Frame and animation hashes are named directly by the profile; a still is
/// carried as bytes, so it has to be hashed to be recognised.
final myWornHashesProvider = Provider<Set<String>>((ref) {
  final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';
  if (me.isEmpty) return const <String>{};
  final profile = ref.watch(profileProvider.select((p) => p[me]));
  final worn = <String>{};
  for (final id in [
    profile?.avatarFrame,
    profile?.avatarAnim,
    profile?.bannerAnim,
  ]) {
    if (id != null && _kHex64.hasMatch(id)) worn.add(id);
  }
  final avatar = ref.watch(avatarProvider.select((c) => c[me]));
  if (avatar != null && avatar.isNotEmpty) worn.add(digestOfBytes(avatar));
  final banner = ref.watch(bannerProvider(me)).valueOrNull;
  if (banner != null && banner.isNotEmpty) worn.add(digestOfBytes(banner));
  return worn;
});

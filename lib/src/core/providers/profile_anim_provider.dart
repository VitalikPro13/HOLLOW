import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/emotes.dart' as emotes_api;

import 'emote_provider.dart' show clearRequestedEmotes, requestAssetOnce;
import 'profile_provider.dart';

/// A person's ANIMATED avatar and banner art, keyed by CONTENT HASH.
///
/// A profile carries only the hash; the animation rides the content-addressed
/// asset rail and the STILL companion stays inside the profile blob. That split
/// is the bandwidth fix: a profile update is PUSHED to everyone who syncs with
/// you, so before this every reconnect re-shipped megabytes of unchanged GIF.
///
/// Avatar and banner share one cache and one `AssetKind`: they share a
/// replication profile, so nothing downstream needs to tell them apart.
class ProfileAnimNotifier extends Notifier<Map<String, Uint8List>> {
  /// Hashes read from disk or in flight, so a rebuild storm can't re-ask.
  final _loading = <String>{};

  /// Hash -> the peer we asked for it, for hashes we don't hold yet. The rail
  /// asks ONCE per session, so a fresh profile announce from that peer (what a
  /// reconnect produces) is the signal to try again.
  final _awaiting = <String, String>{};

  @override
  Map<String, Uint8List> build() => {};

  /// Load [hash]'s art, pulling it from [peerHint]'s devices when we have no
  /// copy. Safe to call from build (it defers the FFI).
  void ensure(String hash, {String? peerHint}) {
    if (!isProfileAnimHash(hash) ||
        state.containsKey(hash) ||
        _loading.contains(hash) ||
        // Already asked and still waiting: without this every rebuild of every
        // avatar we don't hold fires a fresh SQLCipher query across the FFI.
        _awaiting.containsKey(hash)) {
      return;
    }
    _loading.add(hash);
    Future.microtask(() => _load(hash, peerHint));
  }

  Future<void> _load(String hash, String? peerHint) async {
    try {
      final bytes = await emotes_api.getEmoteBytes(hash: hash);
      if (bytes != null && bytes.isNotEmpty) {
        _awaiting.remove(hash);
        state = {...state, hash: bytes};
        return;
      }
      if (peerHint != null && peerHint.isNotEmpty) {
        _awaiting[hash] = peerHint;
        requestAssetOnce(hash, kind: 'profile', peerHint: peerHint);
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load animated profile media $hash: $e');
    } finally {
      _loading.remove(hash);
    }
  }

  /// Put media we just authored straight into the cache, so the settings
  /// preview paints it without a round trip back through the store.
  void seed(String hash, Uint8List bytes) {
    _awaiting.remove(hash);
    state = {...state, hash: bytes};
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

  /// A peer re-announced: retry anything of theirs we asked for and never got.
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

final profileAnimProvider =
    NotifierProvider<ProfileAnimNotifier, Map<String, Uint8List>>(
  ProfileAnimNotifier.new,
);

final _kAnimHash = RegExp(r'^[0-9a-f]{64}$');

/// Whether [hash] names animated profile media on the asset rail. `''` (the
/// common case, still-only) is not a reference.
bool isProfileAnimHash(String hash) =>
    hash.length == 64 && _kAnimHash.hasMatch(hash);

/// [peerId]'s animated AVATAR bytes, or null when they have no animated variant
/// or we don't hold it yet; callers keep painting the still while a pull is in
/// flight. Safe to call from `build`: the pull is deferred.
Uint8List? watchAnimatedAvatar(WidgetRef ref, String peerId) =>
    _watchAnim(ref, peerId,
        ref.watch(profileProvider.select((p) => p[peerId]?.avatarAnim)) ?? '');

/// The banner twin of [watchAnimatedAvatar].
Uint8List? watchAnimatedBanner(WidgetRef ref, String peerId) =>
    _watchAnim(ref, peerId,
        ref.watch(profileProvider.select((p) => p[peerId]?.bannerAnim)) ?? '');

Uint8List? _watchAnim(WidgetRef ref, String peerId, String hash) {
  if (!isProfileAnimHash(hash)) return null;
  final bytes = ref.watch(profileAnimProvider.select((m) => m[hash]));
  if (bytes == null) {
    // Capture the notifier NOW (valid during build) so the deferred pull
    // doesn't touch `ref` after the widget is disposed.
    final anims = ref.read(profileAnimProvider.notifier);
    Future.microtask(() => anims.ensure(hash, peerHint: peerId));
  }
  return bytes;
}

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/verification.dart' as verification_api;

/// Master identities whose safety number the user has confirmed out of band.
///
/// MASTER-KEYED, always. A verified flag stored against a per-device peer_id
/// would stop applying the moment that contact linked or dropped a device, and
/// a badge that quietly stops reflecting reality asserts a safety that is gone.
class VerifiedPeersNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  /// Load verified contacts from the database. Called once at shell startup.
  Future<void> load() async {
    try {
      final pairs = await verification_api.getVerifiedPeers();
      state = pairs.map((p) => p.$1).toSet();
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load verified peers: $e');
    }
  }

  /// Mark a contact as verified. Rethrows so the call site can show a failure —
  /// silently failing here would leave the user believing they verified someone.
  Future<void> verify(String peerId) async {
    final master = ref.read(deviceLinkProvider).identityOf(peerId);
    await verification_api.setPeerVerified(peerId: master);
    state = {...state, master};
  }

  /// Withdraw verification. Rethrows for the same reason as [verify].
  Future<void> unverify(String peerId) async {
    final master = ref.read(deviceLinkProvider).identityOf(peerId);
    await verification_api.removePeerVerified(peerId: master);
    state = state.where((id) => id != master).toSet();
  }

  /// Whether this contact is verified. Accepts a device OR master id.
  bool isVerified(String peerId) =>
      state.contains(ref.read(deviceLinkProvider).identityOf(peerId));
}

final verifiedPeersProvider =
    NotifierProvider<VerifiedPeersNotifier, Set<String>>(
        VerifiedPeersNotifier.new);

/// Reactive "is this contact verified?" for widgets. Accepts a device OR master
/// id and rebuilds when either the verified set or the device map changes.
final isPeerVerifiedProvider = Provider.family<bool, String>((ref, peerId) {
  final master = ref.watch(deviceLinkProvider).identityOf(peerId);
  return ref.watch(verifiedPeersProvider).contains(master);
});

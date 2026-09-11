import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/wipe.dart' as wipe_api;

/// How the identity file is protected right now. Settings > Security reloads
/// this after every change it makes, and the duress card reads the same answer
/// so the two can never disagree about whether a password prompt exists.
final identityProtectionProvider =
    FutureProvider<identity_api.ProtectionStatus>(
  (ref) => identity_api.getIdentityProtectionStatus(),
);

/// Whether a duress code is set, its scope, and whether this identity can have
/// one at all (a duress code needs a password prompt).
///
/// Depends on [identityProtectionProvider] so enabling a password refreshes
/// availability without a second invalidation to remember.
final duressStatusProvider = FutureProvider<identity_api.DuressStatus>(
  (ref) async {
    await ref.watch(identityProtectionProvider.future);
    return identity_api.duressStatus();
  },
);

/// True when this contact announced their identity destroyed. Read once per
/// conversation and invalidated on `IdentityDestroyedByFriend`.
final identityDestroyedProvider =
    FutureProvider.family<bool, String>((ref, masterPeerId) async {
  final at = await wipe_api.identityDestroyedAt(masterPeerId: masterPeerId);
  return at != null;
});

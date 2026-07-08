import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';

/// The peer id of the "Saved messages" conversation — a DM with your OWN
/// master identity (recipient == self). The Rust side stores locally and fans
/// only to sibling devices, so this behaves like any other DM once opened.
///
/// `identityProvider.peerId` is already the MASTER id, but we collapse through
/// the resolver anyway (a perfect no-op on an already-master id) as
/// belt-and-braces — matching every other per-person lookup in the app.
///
/// `null` until the identity has loaded.
final savedMessagesPeerIdProvider = Provider<String?>((ref) {
  final ownId = ref.watch(identityProvider).peerId;
  if (ownId == null || ownId.isEmpty) return null;
  return ref.watch(deviceLinkProvider).identityOf(ownId);
});

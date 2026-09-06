import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';

/// The peer id of the "Saved messages" conversation, a DM with your OWN master
/// identity. Rust stores locally and fans only to sibling devices, so it
/// behaves like any other DM. `null` until the identity has loaded.
final savedMessagesPeerIdProvider = Provider<String?>((ref) {
  final ownId = ref.watch(identityProvider).peerId;
  if (ownId == null || ownId.isEmpty) return null;
  return ref.watch(deviceLinkProvider).identityOf(ownId);
});

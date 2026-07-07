import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;

/// The replicated showcase assets (game covers, artwork) for a peer's
/// profile, keyed by content hash. Pure local read — the bundle arrived via
/// profile replication; viewers never fetch anything.
///
/// Invalidated on `ProfileUpdated` (event_provider) alongside avatar/banner.
final showcaseAssetsProvider =
    FutureProvider.family<Map<String, Uint8List>, String>((ref, peerId) async {
  try {
    final assets = await showcase_api.getShowcaseAssets(peerId: peerId);
    return {for (final a in assets) a.hash: a.bytes};
  } catch (_) {
    return const {};
  }
});

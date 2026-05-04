import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Lazy banner provider: loads banner bytes on-demand per peer.
final bannerProvider =
    FutureProvider.family<Uint8List?, String>((ref, peerId) async {
  return await storage_api.getBanner(peerId: peerId);
});

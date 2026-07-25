import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:hollow/src/rust/api/storage.dart' as ffi;

/// Thin wrapper around the FFI storage layer for testability.
class StorageService {
  Future<void> openMessageStore() => ffi.openMessageStore();

  // `saveMessage` / `saveChannelMessage` were removed in 0.8.5 — they wrote
  // unsigned, message_id-less rows that no peer would accept through sync, and
  // nothing ever called them. Message rows come from the node's own signing
  // send/receive paths.

  Future<List<ffi.StoredMessage>> loadMessages({
    required String peerId,
    required int limit,
  }) => ffi.loadMessages(peerId: peerId, limit: limit);

  Future<List<ffi.StoredChannelMessage>> loadChannelMessages({
    required String serverId,
    required String channelId,
    required int limit,
  }) => ffi.loadChannelMessages(
    serverId: serverId,
    channelId: channelId,
    limit: limit,
  );
}

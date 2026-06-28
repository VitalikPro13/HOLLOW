import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks who is typing where. Ephemeral — no persistence.
///
/// State: Map of context key to Set of peer IDs where key is:
/// - For DMs: the peer ID
/// - For channels: "serverId:channelId"
class TypingNotifier extends Notifier<Map<String, Set<String>>> {
  final Map<String, Map<String, Timer>> _timers = {};

  @override
  Map<String, Set<String>> build() {
    // Cancel any pending 5s expiry timers if this provider is disposed, so they
    // don't fire clearTyping() into a disposed notifier.
    ref.onDispose(() {
      for (final inner in _timers.values) {
        for (final t in inner.values) {
          t.cancel();
        }
      }
      _timers.clear();
    });
    return {};
  }

  /// Mark a peer as typing in a context (DM peer ID or "serverId:channelId").
  /// Auto-expires after 5 seconds.
  void setTyping(String key, String peerId) {
    // Cancel existing timer for this peer in this context.
    _timers[key]?[peerId]?.cancel();

    // Add to state.
    final updated = Map<String, Set<String>>.from(state);
    updated[key] = {...(updated[key] ?? {}), peerId};
    state = updated;

    // Set expiry timer (5 seconds).
    _timers.putIfAbsent(key, () => {});
    _timers[key]![peerId] = Timer(const Duration(seconds: 5), () {
      clearTyping(key, peerId);
    });
  }

  /// Clear typing for a peer in a context.
  void clearTyping(String key, String peerId) {
    _timers[key]?[peerId]?.cancel();
    _timers[key]?.remove(peerId);

    final updated = Map<String, Set<String>>.from(state);
    final peers = updated[key];
    if (peers != null) {
      peers.remove(peerId);
      if (peers.isEmpty) {
        updated.remove(key);
      }
    }
    state = updated;
  }

  /// Clear all typing for a context (e.g., when switching channels).
  void clearContext(String key) {
    _timers[key]?.forEach((_, timer) => timer.cancel());
    _timers.remove(key);

    final updated = Map<String, Set<String>>.from(state);
    updated.remove(key);
    state = updated;
  }
}

final typingProvider =
    NotifierProvider<TypingNotifier, Map<String, Set<String>>>(
        TypingNotifier.new);

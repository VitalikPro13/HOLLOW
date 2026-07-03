import 'dart:async';

import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Fire-and-forget relay-topic subscription that is safe to call BEFORE the
/// node is running.
///
/// A cold-start push tap opens a channel the instant the shell mounts, while
/// `start_node()` is still seconds away (identity unlock + relay-status fetch
/// run first in `_bootstrap`). A bare `network_api.subscribeChannels()` call
/// then rejects with "Node is not running" — and because every caller is
/// fire-and-forget, the rejection escapes any surrounding sync try/catch and
/// lands in the zone crash handler. Worse, the failed call registers nothing,
/// so the tapped channel never gets its relay topic and live broadcasts
/// silently stop arriving until the chat is reopened.
///
/// This wrapper retries until the node is up (~30s window) and never lets an
/// error escape. Rust's `SubscribeChannels` REPLACES the per-server topic set,
/// so each retry loop carries a per-server sequence number and abandons itself
/// the moment a newer subscription for the same server is issued — a stale
/// retry must never clobber the topics of a channel opened later.
final _subscribeSeq = <String, int>{};

void subscribeChannelTopics({
  required String serverId,
  required List<String> channelIds,
}) {
  final seq = (_subscribeSeq[serverId] ?? 0) + 1;
  _subscribeSeq[serverId] = seq;
  unawaited(_subscribeWithRetry(serverId, channelIds, seq));
}

Future<void> _subscribeWithRetry(
    String serverId, List<String> channelIds, int seq) async {
  for (var attempt = 0; attempt < 15; attempt++) {
    if (_subscribeSeq[serverId] != seq) return; // superseded — bail out
    try {
      await network_api.subscribeChannels(
          serverId: serverId, channelIds: channelIds);
      return;
    } catch (_) {
      // Node not running yet (or restarting) — retry shortly.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

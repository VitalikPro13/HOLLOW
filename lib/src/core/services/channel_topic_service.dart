import 'dart:async';

import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Fire-and-forget relay-topic subscription, safe to call BEFORE the node is
/// running: a cold-start push tap opens a channel while `start_node()` is
/// still seconds away, and a bare `subscribeChannels()` then rejects into the
/// zone crash handler AND registers nothing, so the tapped channel never gets
/// its relay topic and live broadcasts silently stop arriving.
///
/// Rust's `SubscribeChannels` REPLACES the per-server topic set, so each retry
/// loop carries a per-server sequence number and abandons itself once a newer
/// subscription for that server is issued: a stale retry must never clobber
/// the topics of a channel opened later.
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
    if (_subscribeSeq[serverId] != seq) return; // superseded
    try {
      await network_api.subscribeChannels(
          serverId: serverId, channelIds: channelIds);
      return;
    } catch (_) {
      // Node not running yet or restarting; retry shortly.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
}

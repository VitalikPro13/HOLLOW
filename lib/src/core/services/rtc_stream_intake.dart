import 'dart:async';
import 'dart:collection';

/// The WS stream lane's limits in Rust (`file_transfer::DEFAULT_MAX_FILE_SIZE`,
/// `file_handler::AES_GCM_TAG` and `SHARD_HEADER_SLACK`, `share_handler::CHUNK_SIZE`,
/// `ws_stream_transfer`'s receive caps), pinned equal by
/// `test/rtc_stream_intake_test.dart`.
const int kRtcSendLimit = 34 * 1024 * 1024;
const int kRtcGcmTag = 16;
const int kRtcShardHeaderSlack = 4096;
const int kRtcShareChunkSize = 262144;
const int kMaxRtcStreamsPerSender = 16;
const int kMaxRtcStreams = 128;
const Duration kRtcStreamTakeoverIdle = Duration(seconds: 10);

/// Streams one connection sends at once, under what a receiver keeps open per
/// sender, so our own bursts never meet that cap.
const int kMaxRtcSendsPerConn = 8;

/// Whether a send of [kind] may ride a sibling device's channel when the target
/// device has none open. A file or shard stream id names the one device it is for,
/// so those ride that device's own channel or fail over to Rust's relay retry.
bool rtcSendMayUseSibling(String kind) => kind == 'share_chunk';

/// The most bytes a data channel stream of [kind] may declare.
int rtcStreamCeiling(String kind) => switch (kind) {
      'shard' => kRtcSendLimit + kRtcGcmTag + kRtcShardHeaderSlack,
      'share_chunk' => kRtcShareChunkSize + kRtcGcmTag,
      _ => kRtcSendLimit + kRtcGcmTag,
    };

/// An incoming data channel stream as the receive gate sees it.
abstract interface class RtcIncomingStream {
  /// The connection that opened it, lane included: only it extends the stream.
  String get sender;
  int get totalSize;
  int get bytesReceived;
  DateTime get lastFrameAt;
}

/// What a first frame does: refused, or opened once [evict] is discarded.
class RtcStreamOpen {
  final String? refusal;
  final List<String> evict;

  const RtcStreamOpen._(this.refusal, this.evict);
  const RtcStreamOpen.refused(String why) : this._(why, const []);
  const RtcStreamOpen.opened(List<String> evict) : this._(null, evict);
}

/// Judges a first frame from [sender] opening stream [id] among the [open] ones.
///
/// An id stays its opener's until it idles past [kRtcStreamTakeoverIdle]. A
/// sender past its share pays with its own stalest stream; past the total, the
/// sender holding the most pays, so a flood never evicts a light peer.
RtcStreamOpen rtcStreamOpen<T extends RtcIncomingStream>(
  Map<String, T> open, {
  required String id,
  required String sender,
  required String kind,
  required int totalSize,
  required int firstPayload,
  required DateTime now,
}) {
  final limit = rtcStreamCeiling(kind);
  if (totalSize > limit) {
    return RtcStreamOpen.refused(
        'it declares $totalSize bytes, $limit allowed');
  }
  // Also refuses a u64 size past 2^63, which reads negative here.
  if (firstPayload > totalSize) {
    return const RtcStreamOpen.refused('its first frame runs past its size');
  }
  final held = open[id];
  if (held != null &&
      held.sender != sender &&
      now.difference(held.lastFrameAt) < kRtcStreamTakeoverIdle) {
    return RtcStreamOpen.refused('${held.sender} holds it');
  }

  final kept = Map<String, T>.of(open)..remove(id);
  final evict = <String>[if (held != null) id];
  String? stalestOf(String who) {
    String? stalest;
    DateTime? at;
    for (final e in kept.entries) {
      if (e.value.sender == who &&
          (at == null || e.value.lastFrameAt.isBefore(at))) {
        stalest = e.key;
        at = e.value.lastFrameAt;
      }
    }
    return stalest;
  }

  while (kept.values.where((s) => s.sender == sender).length >=
      kMaxRtcStreamsPerSender) {
    final victim = stalestOf(sender)!;
    kept.remove(victim);
    evict.add(victim);
  }
  while (kept.length >= kMaxRtcStreams) {
    // The newcomer counts its own new stream and wins ties, so it pays first.
    final counts = <String, int>{sender: 1};
    for (final s in kept.values) {
      counts[s.sender] = (counts[s.sender] ?? 0) + 1;
    }
    final heaviest =
        counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    final victim = stalestOf(heaviest);
    if (victim == null) {
      return const RtcStreamOpen.refused('every slot is held');
    }
    kept.remove(victim);
    evict.add(victim);
  }
  return RtcStreamOpen.opened(evict);
}

enum RtcChunk { drop, append, complete, overflow }

/// What a continuation of [payload] bytes from [sender] does to [stream].
RtcChunk rtcChunkVerdict(RtcIncomingStream? stream, String sender, int payload) {
  if (stream == null || stream.sender != sender) return RtcChunk.drop;
  final received = stream.bytesReceived + payload;
  if (received > stream.totalSize) return RtcChunk.overflow;
  return received == stream.totalSize ? RtcChunk.complete : RtcChunk.append;
}

/// Bounds the streams one connection sends at once to [max].
class RtcSendSlots {
  final int max;
  int _busy = 0;
  final Queue<Completer<void>> _waiting = Queue();

  RtcSendSlots([this.max = kMaxRtcSendsPerConn]);

  Future<void> acquire() {
    if (_busy < max) {
      _busy++;
      return Future.value();
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    return turn.future;
  }

  /// Hands the slot to the longest waiting send, if any.
  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else if (_busy > 0) {
      _busy--;
    }
  }
}

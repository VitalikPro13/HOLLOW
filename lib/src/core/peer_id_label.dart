/// How a peer id (a master or a device id) reads on screen. Every id starts
/// with the same "12D3KooW", so the ending is what tells two people apart and
/// what people compare: no label ever drops it.
library;

const _ellipsis = '…';

/// Characters of the ending every shortened id keeps.
const kPeerIdEnding = 6;

/// The most of the shared start a shortened id shows: enough to read as an
/// id, every other character goes to the ending.
const kPeerIdStart = 4;

/// The short form for a name fallback or a compact row, as push banners show
/// it: the first 4, an ellipsis, the last 10.
String shortPeerLabel(String peerId) => peerId.length > 16
    ? '${peerId.substring(0, kPeerIdStart)}$_ellipsis${_lastOf(peerId, 10)}'
    : peerId;

/// The longest form of [peerId] that [fits]: the whole id, else at most
/// [kPeerIdStart] of its start and as much of its ending as fits.
/// With no room at all it still returns the ending.
String fitPeerId(String peerId, bool Function(String shown) fits) {
  if (fits(peerId)) return peerId;
  final floor = _ellipsis + _lastOf(peerId, kPeerIdEnding);
  if (peerId.length <= floor.length) return peerId;
  var lo = kPeerIdEnding + 1, hi = peerId.length - 1, best = 0;
  while (lo <= hi) {
    final kept = (lo + hi) ~/ 2;
    if (fits(_keep(peerId, kept))) {
      best = kept;
      lo = kept + 1;
    } else {
      hi = kept - 1;
    }
  }
  return best == 0 ? floor : _keep(peerId, best);
}

/// [kept] characters of [peerId] around an ellipsis: at most [kPeerIdStart]
/// from the start once the ending has [kPeerIdEnding], the rest from the end.
String _keep(String peerId, int kept) {
  final head = (kept - kPeerIdEnding).clamp(0, kPeerIdStart);
  return peerId.substring(0, head) + _ellipsis + _lastOf(peerId, kept - head);
}

String _lastOf(String s, int n) =>
    s.length <= n ? s : s.substring(s.length - n);

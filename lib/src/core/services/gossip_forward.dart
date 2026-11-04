/// How a voice channel's gossip forwarding tells a forwarded voice from the
/// forwarder's own on the far side of a leg.
///
/// The forwarder sends each forwarded track under a stream id naming its
/// origin, written into the SDP it SENDS (its own local description keeps the
/// native id), so the neighbour can key the SFrame decryptor, the volume and
/// the speaking light to the right person and never mistakes it for the
/// forwarder's microphone.
library;

import 'dart:async';

/// Whether a forwarder puts the voices it hears onto its other legs. Off: the
/// audio device feeds every sending stream on its capture thread, so a re-sent
/// remote track races it there and libwebrtc aborts the process
/// (RTC_CHECK_RUNS_SERIALIZED), and the stream would carry our microphone too.
/// Wants, markers and forward cryptors stay dormant until a transport that
/// owns its own send stream exists.
bool gossipForwardingEnabled = false;

/// The stream-id prefix of a forwarded voice. A stream id is at most 64
/// characters (RFC 8830), and a peer id is 52.
const String kForwardStreamPrefix = 'hfwd-';

/// The SFrame cryptor kind of a forwarded voice from [origin].
String forwardCryptorKind(String origin) => 'fwd:$origin';

final _origin = RegExp(r'^[A-Za-z0-9]{1,59}$');
final _msid = RegExp(r'^(a=(?:ssrc:\d+ )?msid:)(\S+) (\S+)\s*$');

/// [sdp] with each track of [forwarded] (track id to origin) under its origin's
/// stream id. Lines for other tracks are left as they are.
String markForwardedTracks(String sdp, Map<String, String> forwarded) {
  if (forwarded.isEmpty) return sdp;
  final crlf = sdp.contains('\r\n');
  final lines = sdp.split(crlf ? '\r\n' : '\n');
  for (var i = 0; i < lines.length; i++) {
    final m = _msid.firstMatch(lines[i]);
    if (m == null) continue;
    final origin = forwarded[m.group(3)];
    if (origin == null || !_origin.hasMatch(origin)) continue;
    lines[i] = '${m.group(1)}$kForwardStreamPrefix$origin ${m.group(3)}';
  }
  return lines.join(crlf ? '\r\n' : '\n');
}

/// The forwarded tracks a remote [sdp] declares, track id to origin.
Map<String, String> forwardedTracksIn(String sdp) {
  final out = <String, String>{};
  for (final line in sdp.split('\n')) {
    final m = _msid.firstMatch(line.trimRight());
    if (m == null) continue;
    final origin = forwardOriginOfStream(m.group(2)!);
    if (origin != null) out[m.group(3)!] = origin;
  }
  return out;
}

/// The origin a forwarded stream id names, or null for any other stream.
String? forwardOriginOfStream(String streamId) {
  if (!streamId.startsWith(kForwardStreamPrefix)) return null;
  final origin = streamId.substring(kForwardStreamPrefix.length);
  return _origin.hasMatch(origin) ? origin : null;
}

/// The members a listener asks its legs to forward: in gossip mode, everyone it
/// has no [live] leg to, unless that leg is still [settling] in. A neighbour
/// counts only once its leg is up, so one whose leg never formed is still
/// heard; a room whose legs all came up asks for nothing.
Set<String> forwardWants({
  required bool gossip,
  required String self,
  required Set<String> members,
  required Set<String> live,
  required Set<String> settling,
}) {
  if (!gossip) return const {};
  return {
    for (final m in members)
      if (m != self && !live.contains(m) && !settling.contains(m)) m,
  };
}

/// The voices a forwarder sends down [leg]: those the leg asked for that it
/// hears straight from their speaker, never the leg's own or ours.
Set<String> forwardsFor({
  required String leg,
  required String self,
  required Set<String> wanted,
  required Set<String> heard,
}) =>
    {
      for (final o in wanted)
        if (o != leg && o != self && heard.contains(o)) o,
    };

/// One renegotiation per leg per burst of forward changes, so a forwarded
/// voice flows at once without a renegotiation for every track.
class ForwardRenegBatcher {
  ForwardRenegBatcher(this._renegotiate,
      {this.delay = const Duration(milliseconds: 300)});

  final Future<void> Function(String leg) _renegotiate;
  final Duration delay;
  final Map<String, Timer> _due = {};

  /// [leg]'s forwards changed: renegotiate it once the burst settles.
  void touch(String leg) {
    _due[leg]?.cancel();
    _due[leg] = Timer(delay, () {
      _due.remove(leg);
      unawaited(_renegotiate(leg).catchError((_) {}));
    });
  }

  void cancel(String leg) => _due.remove(leg)?.cancel();

  void cancelAll() {
    for (final t in _due.values) {
      t.cancel();
    }
    _due.clear();
  }
}

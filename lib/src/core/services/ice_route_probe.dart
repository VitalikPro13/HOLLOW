import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Which ICE candidate pair a connected peer connection actually settled on.
///
/// Diagnostics for "is this call direct or relayed?" — the line you read in
/// `hollow_debug.log` to confirm what a connection is doing. `WebRtcService`
/// also feeds [isDirect] into the Rust gossip peer scorer.
class IceRoute {
  final String localType;
  final String remoteType;
  final String proto;

  const IceRoute(this.localType, this.remoteType, this.proto);

  /// True when neither end went through a TURN relay.
  bool get isDirect => localType != 'relay' && remoteType != 'relay';

  String get label => localType == 'relay' || remoteType == 'relay'
      ? 'TURN (relayed)'
      : localType == 'srflx' || remoteType == 'srflx'
          ? 'STUN (direct P2P)'
          : localType == 'host' && remoteType == 'host'
              ? 'LAN (direct)'
              : 'P2P ($localType/$remoteType)';

  @override
  String toString() =>
      '$label (local=$localType remote=$remoteType proto=$proto)';
}

/// Delays before each probe attempt, cumulative ≈ 7s.
///
/// A single shot at 1s was the old behaviour and it was a race: the peer
/// connection reports `connected` as soon as a check succeeds, but the
/// candidate pair does not always read back as `succeeded` in `getStats()`
/// that early. On a relayed path (every path, with "Always relay calls" on)
/// the extra round trip through TURN made the 1s shot miss most of the time,
/// so the log said "no succeeded candidate pair found" for calls that were in
/// fact connected and passing audio.
const List<Duration> _kProbeSchedule = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// Poll [resolvePc] until the succeeded candidate pair shows up in stats, or
/// the schedule runs out. Returns null if the connection went away or never
/// reported a pair.
///
/// [resolvePc] is a callback, not a bare connection, so a caller whose peer
/// connection can be superseded mid-probe (glare, renegotiation) bails instead
/// of reporting a route for a connection it no longer owns.
Future<IceRoute?> probeIceRoute(RTCPeerConnection? Function() resolvePc) async {
  for (final delay in _kProbeSchedule) {
    await Future<void>.delayed(delay);
    final pc = resolvePc();
    if (pc == null) return null;
    try {
      final route = _routeFromStats(await pc.getStats());
      if (route != null) return route;
    } catch (_) {
      // getStats throws once the PC is closed — nothing left to report.
      return null;
    }
  }
  return null;
}

/// One immediate stats pass — no retry schedule. For callers that need a
/// best-effort route hint NOW from an already-connected PC (the viewer's
/// `route` field on screen_watch, media forwarding step 3). Returns null when
/// no succeeded pair is visible yet; the hint is advisory, so callers just
/// send "" and the fallback ladder corrects any wrong guess.
Future<IceRoute?> probeIceRouteOnce(RTCPeerConnection pc) async {
  try {
    return _routeFromStats(await pc.getStats());
  } catch (_) {
    return null;
  }
}

IceRoute? _routeFromStats(List<StatsReport> stats) {
  StatsReport? pair;
  for (final r in stats) {
    if (r.type != 'candidate-pair' || r.values['state'] != 'succeeded') continue;
    pair = r;
    // Several pairs can read as succeeded; the nominated one is the one
    // actually carrying media, so stop as soon as we see it.
    if (r.values['nominated'] == true) break;
  }
  if (pair == null) return null;

  final localId = pair.values['localCandidateId'] as String?;
  final remoteId = pair.values['remoteCandidateId'] as String?;
  String localType = '?', remoteType = '?', proto = '';
  for (final r in stats) {
    if (r.type == 'local-candidate' && r.id == localId) {
      localType = (r.values['candidateType'] as String?) ?? '?';
      proto = (r.values['protocol'] as String?) ?? '';
    }
    if (r.type == 'remote-candidate' && r.id == remoteId) {
      remoteType = (r.values['candidateType'] as String?) ?? '?';
    }
  }
  return IceRoute(localType, remoteType, proto);
}

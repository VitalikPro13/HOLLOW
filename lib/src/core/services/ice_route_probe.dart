import 'package:flutter_webrtc/flutter_webrtc.dart';

/// How a call's media reaches us, as the call UI names it.
enum MediaRoute {
  /// Host or server-reflexive on both ends: LAN, or straight through the NAT.
  direct,

  /// A TURN relay on at least one end.
  relayed,

  /// A screen share passed along by another member's app.
  memberForwarder,

  /// A screen share passed along by the relay's forwarder.
  relayForwarder;

  bool get isForwarded => this == memberForwarder || this == relayForwarder;
}

/// Which ICE candidate pair a connected peer connection actually settled on.
///
/// Answers "is this call direct or relayed?" for the call UI's route badge and
/// the `hollow_debug.log` line. [isDirect] also feeds the Rust gossip scorer.
class IceRoute {
  final String localType;
  final String remoteType;
  final String proto;

  const IceRoute(this.localType, this.remoteType, this.proto);

  /// True when neither end went through a TURN relay.
  bool get isDirect => localType != 'relay' && remoteType != 'relay';

  /// What the call UI says about this pair. A forwarder leg is named by its
  /// lane, never by its pair (the pair only describes the hop to the forwarder).
  MediaRoute get mediaRoute => isDirect ? MediaRoute.direct : MediaRoute.relayed;

  String get label => localType == 'relay' || remoteType == 'relay'
      ? 'TURN (relayed)'
      : localType == 'srflx' || remoteType == 'srflx'
          ? 'STUN (direct P2P)'
          : localType == 'host' && remoteType == 'host'
              ? 'LAN (direct)'
              : 'P2P ($localType/$remoteType)';

  /// The raw pair facts without the TURN/STUN/LAN taxonomy, for lanes the
  /// taxonomy does not describe (forwarder legs, where the label misleads).
  String get detail => 'local=$localType remote=$remoteType proto=$proto';

  @override
  String toString() => '$label ($detail)';
}

/// Delays before each probe attempt, cumulative about 7s.
///
/// A single shot at 1s raced: the connection reports `connected` as soon as a
/// check succeeds, but the pair does not always read back as `succeeded` in
/// `getStats()` that early, so the log claimed no succeeded pair for calls
/// that were in fact connected and passing audio.
const List<Duration> _kProbeSchedule = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
];

/// Polls until the succeeded candidate pair shows up in stats, or the
/// schedule runs out. Null if the connection went away or never reported one.
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
      final route = iceRouteFromStats(await pc.getStats());
      if (route != null) return route;
    } catch (_) {
      // getStats throws once the PC is closed.
      return null;
    }
  }
  return null;
}

/// One immediate stats pass, no retry schedule, for a best-effort route hint
/// from an already-connected PC. Null when no succeeded pair is visible yet;
/// the hint is advisory and the fallback ladder corrects a wrong guess.
Future<IceRoute?> probeIceRouteOnce(RTCPeerConnection pc) async {
  try {
    return iceRouteFromStats(await pc.getStats());
  } catch (_) {
    return null;
  }
}

/// The pair carrying media in one `getStats()` reading, null when none has
/// succeeded yet.
///
/// The transport's selected pair wins: after an ICE restart the old pair can
/// still read `succeeded` (and even nominated) beside the new one.
IceRoute? iceRouteFromStats(List<StatsReport> stats) {
  String? selectedId;
  for (final r in stats) {
    if (r.type != 'transport') continue;
    final id = r.values['selectedCandidatePairId'];
    if (id is String && id.isNotEmpty) {
      selectedId = id;
      break;
    }
  }

  StatsReport? pair;
  if (selectedId != null) {
    for (final r in stats) {
      if (r.type == 'candidate-pair' && r.id == selectedId) {
        pair = r;
        break;
      }
    }
  }
  if (pair == null) {
    for (final r in stats) {
      if (r.type != 'candidate-pair' || r.values['state'] != 'succeeded') {
        continue;
      }
      pair = r;
      // Several pairs can read as succeeded; the nominated one carries media.
      if (r.values['nominated'] == true) break;
    }
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

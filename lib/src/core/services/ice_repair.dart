import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'ice_route_probe.dart';

/// "Direct whenever direct is possible" — detect a peer connection that
/// settled on a TURN relay pair even though BOTH sides advertised a
/// host/server-reflexive candidate, so one ICE restart can be scheduled to
/// re-run the checks on a warmed network.
///
/// Why this exists: libwebrtc nominates whichever candidate pair completes its
/// connectivity check FIRST, and TURN's pre-allocated relay needs no hole
/// punch — so it routinely wins the race by a single RTT on paths where a
/// direct pair would have worked fine. Once nominated, ICE never migrates on
/// its own. Every viewer left on a relay pair costs the relay `2·B` bytes and,
/// on the forwarder lane, is one fewer peer branch the tree can use.
///
/// 100% direct is impossible and NOT the goal: symmetric NATs and UDP-hostile
/// firewalls are the reason TURN exists. This targets only the nomination-race
/// losses, and gives up after ONE attempt.
///
/// The whole detector reads from a single `getStats()` pass — the candidate
/// tables enumerate what BOTH sides offered, so no signaling change is needed
/// to know a direct pair was viable.
@immutable
class IceRepairVerdict {
  /// The route the connection actually settled on (null = no succeeded pair
  /// visible yet — too early to judge).
  final IceRoute? route;

  /// A non-relay candidate existed on OUR side.
  final bool localHadDirect;

  /// A non-relay candidate existed on the REMOTE side.
  final bool remoteHadDirect;

  const IceRepairVerdict({
    required this.route,
    required this.localHadDirect,
    required this.remoteHadDirect,
  });

  /// True when the connection is relayed but both ends offered a direct
  /// candidate — the repairable case, and the only one worth an ICE restart.
  bool get shouldRepair =>
      route != null && !route!.isDirect && localHadDirect && remoteHadDirect;

  String get detail => route == null
      ? 'no succeeded pair'
      : '${route!.detail} localDirect=$localHadDirect '
          'remoteDirect=$remoteHadDirect';
}

/// Candidate types that mean "not through a TURN relay".
bool _isDirectType(String? t) => t != null && t != 'relay' && t.isNotEmpty;

/// One stats pass: what route did we settle on, and did both sides have a
/// direct candidate to offer?
///
/// Returns null when the connection is gone or stats are unreadable.
Future<IceRepairVerdict?> assessIceRepair(RTCPeerConnection pc) async {
  final List<StatsReport> stats;
  try {
    stats = await pc.getStats();
  } catch (_) {
    // getStats throws once the PC is closed — nothing to judge.
    return null;
  }

  IceRoute? route;
  try {
    route = await probeIceRouteOnce(pc);
  } catch (_) {
    route = null;
  }

  var localHadDirect = false;
  var remoteHadDirect = false;
  for (final r in stats) {
    final type = r.values['candidateType'] as String?;
    if (r.type == 'local-candidate' && _isDirectType(type)) {
      localHadDirect = true;
    } else if (r.type == 'remote-candidate' && _isDirectType(type)) {
      remoteHadDirect = true;
    }
  }

  return IceRepairVerdict(
    route: route,
    localHadDirect: localHadDirect,
    remoteHadDirect: remoteHadDirect,
  );
}

/// Which side initiates a repair when BOTH detect the same relayed pair.
///
/// An ICE restart is a renegotiation trigger, so two simultaneous restarts are
/// textbook glare. Reuse the polite-peer convention the rest of the codebase
/// already arbitrates with: the lexicographically LOWER id initiates, the
/// other side just answers the offer it receives.
bool shouldInitiateIceRepair(String localId, String remoteId) =>
    localId.compareTo(remoteId) < 0;

/// Restart ICE on [pc]. The caller must follow this with its lane's normal
/// renegotiation offer — `restartIce()` only arms fresh ICE credentials; the
/// next `createOffer` carries them.
///
/// Deliberately `restartIce()` and NOT `createOffer({'iceRestart': true})`:
/// on the native Windows path the W3C flat constraint is silently dropped
/// (`ParseMediaConstraints` reads only the `mandatory`/`optional` sub-maps), so
/// the offer would look identical and nothing would restart.
///
/// ICE restart is make-before-break by construction: media keeps flowing on the
/// existing pair until the new one connects.
Future<bool> restartIceOn(RTCPeerConnection pc) async {
  try {
    await pc.restartIce();
    return true;
  } catch (e) {
    debugPrint('[HOLLOW-ICE-REPAIR] restartIce failed: $e');
    return false;
  }
}

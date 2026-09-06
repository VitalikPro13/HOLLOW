import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'ice_route_probe.dart';

/// Detects a peer connection that settled on a TURN relay pair even though
/// BOTH sides advertised a direct candidate, so one ICE restart can re-run
/// the checks on a warmed network.
///
/// libwebrtc nominates whichever pair completes its check FIRST, and TURN's
/// pre-allocated relay needs no hole punch, so it routinely wins by an RTT on
/// a path a direct pair would have carried; ICE never migrates afterwards.
/// Only that nomination-race loss is targeted, and only once: symmetric NATs
/// and UDP-hostile firewalls are why TURN exists at all.
@immutable
class IceRepairVerdict {
  /// The route settled on. Null = no succeeded pair yet, too early to judge.
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

  /// Relayed while both ends offered a direct candidate: the repairable case.
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
/// direct candidate? Null when the connection is gone or stats unreadable.
Future<IceRepairVerdict?> assessIceRepair(RTCPeerConnection pc) async {
  final List<StatsReport> stats;
  try {
    stats = await pc.getStats();
  } catch (_) {
    // getStats throws once the PC is closed.
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
/// An ICE restart is a renegotiation trigger, so two at once are glare. Same
/// polite-peer convention as the rest of the codebase: the lower id offers.
bool shouldInitiateIceRepair(String localId, String remoteId) =>
    localId.compareTo(remoteId) < 0;

/// Restarts ICE on [pc]. The caller must follow with its lane's renegotiation
/// offer, since `restartIce()` only arms fresh ICE credentials.
///
/// Deliberately not `createOffer({'iceRestart': true})`: on the native Windows
/// path the W3C flat constraint is silently dropped (`ParseMediaConstraints`
/// reads only the `mandatory`/`optional` sub-maps), so nothing would restart.
/// The restart is make-before-break, so media keeps flowing on the existing
/// pair until the new one connects.
Future<bool> restartIceOn(RTCPeerConnection pc) async {
  try {
    await pc.restartIce();
    return true;
  } catch (e) {
    debugPrint('[HOLLOW-ICE-REPAIR] restartIce failed: $e');
    return false;
  }
}

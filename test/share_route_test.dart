/// What a watched share's route badge is fed (0.14, `project_call_route_badge_014`):
/// a share our own app forwards never reads as another member's, and a leg's
/// route follows its transport (cleared while it is down, moved by the stats
/// the leg already reads).
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/forwarder_info_provider.dart';
import 'package:hollow/src/core/providers/media_route_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/ice_route_probe.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

StatsReport _r(String id, String type, Map<String, dynamic> values) =>
    StatsReport(id, type, 0, values);

/// A stats reading whose selected pair is [local] to [remote].
List<StatsReport> _reading(String local, String remote) => [
      _r('T', 'transport', {'selectedCandidatePairId': 'P'}),
      _r('P', 'candidate-pair', {
        'state': 'succeeded',
        'nominated': true,
        'localCandidateId': 'L',
        'remoteCandidateId': 'R',
      }),
      _r('L', 'local-candidate', {'candidateType': local, 'protocol': 'udp'}),
      _r('R', 'remote-candidate', {'candidateType': remote}),
    ];

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  group('a viewer', () {
    ({ProviderContainer c, VoiceChannelNotifier vc}) room() {
      final c = ProviderContainer(overrides: [
        voiceChannelProvider.overrideWith(_Room.new),
        forwarderInfoProvider.overrideWith(_Vps.new),
      ]);
      addTearDown(c.dispose);
      final vc = c.read(voiceChannelProvider.notifier);
      vc.debugAdoptCall(_Mesh(), incomingShares: {'sharer': _Share()});
      return (c: c, vc: vc);
    }

    const pair = IceRoute('host', 'host', 'udp');

    test('whose own app forwards the share is never told another member does',
        () {
      final r = room();
      r.vc.debugShareLegRouted('sharer', pair,
          delivererPeer: 'dev-me', viaForwarder: true);
      expect(r.c.read(vcShareRouteProvider)['sharer'], isNull,
          reason: 'the pair is a hop inside this device');
    });

    test('hears who forwards when someone else does', () {
      final r = room();
      r.vc.debugShareLegRouted('sharer', pair,
          delivererPeer: 'dev-mira', viaForwarder: true);
      expect(r.c.read(vcShareRouteProvider)['sharer'],
          MediaRoute.memberForwarder);
      r.vc.debugShareLegRouted('sharer', pair,
          delivererPeer: 'vps', viaForwarder: true);
      expect(r.c.read(vcShareRouteProvider)['sharer'],
          MediaRoute.relayForwarder);
      r.vc.debugShareLegRouted('sharer', const IceRoute('relay', 'host', 'udp'),
          delivererPeer: 'sharer', viaForwarder: false);
      expect(r.c.read(vcShareRouteProvider)['sharer'], MediaRoute.relayed);
      r.vc.debugShareLegRouted('sharer', null,
          delivererPeer: 'sharer', viaForwarder: false);
      expect(r.c.read(vcShareRouteProvider).containsKey('sharer'), isFalse);
    });
  });

  group('a share leg', () {
    test('clears its route while the transport is down and reads it again',
        () {
      final leg = ScreenShareService(localPeerId: 'me', iceServers: const {});
      final heard = <MediaRoute?>[];
      leg.onRoute = (route) => heard.add(route?.mediaRoute);

      leg.debugStatsReading(_reading('host', 'srflx'));
      leg.debugConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
      leg.debugStatsReading(_reading('relay', 'host'));
      leg.debugConnectionState(
          RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      expect(heard, [MediaRoute.direct, null, MediaRoute.relayed, null]);
    });

    test('follows the selected pair in the stats it already reads', () {
      final leg = ScreenShareService(localPeerId: 'me', iceServers: const {});
      final heard = <MediaRoute?>[];
      leg.onRoute = (route) => heard.add(route?.mediaRoute);

      leg.debugStatsReading(_reading('host', 'host'));
      leg.debugStatsReading(_reading('host', 'host'));
      leg.debugStatsReading(const []);
      leg.debugStatsReading(_reading('relay', 'relay'));
      expect(heard, [MediaRoute.direct, MediaRoute.relayed],
          reason: 'once per change; a reading with no pair keeps the route');
    });

    test('the leg reads its route in the periodic stats poll it already runs',
        () {
      // Source check: the liveness poll is the share's one periodic getStats;
      // the route rides it rather than a timer of its own.
      final src = _source('lib/src/core/services/screen_share_service.dart');
      expect(_body(src, 'Future<bool> _consentLooksStale('),
          contains('_noteRouteIn(stats)'));
    });
  });
}

/// The body of the method whose declaration starts with [signature].
String _body(String src, String signature) {
  final at = src.indexOf(signature);
  expect(at, greaterThanOrEqualTo(0), reason: 'no $signature');
  final open = src.indexOf('{', src.indexOf(')', at));
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    if (src[i] == '{') depth++;
    if (src[i] == '}' && --depth == 0) return src.substring(open, i + 1);
  }
  fail('unbalanced $signature');
}

String _source(String path) =>
    (File(path).readAsStringSync()).replaceAll('\r\n', '\n');

class _Room extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        currentServerId: 'srv',
        currentChannelId: 'vc',
        currentChannelName: 'room',
        peerScreenSharing: {'sharer': true},
        watchingScreenShares: {'sharer'},
      );
}

class _Vps extends ForwarderInfoNotifier {
  @override
  ForwarderInfo build() => const ForwarderInfo(peerId: 'vps', online: true);
}

class _Mesh extends VoiceChannelService {
  _Mesh() : super(localPeerId: 'dev-me', iceServers: const {});
}

class _Share extends ScreenShareService {
  _Share() : super(localPeerId: 'dev-me', iceServers: const {});
}

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}

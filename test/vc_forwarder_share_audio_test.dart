import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack;
import 'package:hollow/src/core/providers/forwarder_info_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_frame_cryptor.dart';

/// Issue #135. A viewer the sharer routed through a media forwarder got the
/// video and no share audio: the audio capture lived on the direct video leg,
/// which a forwarder-served viewer never has. The share now runs ONE capture,
/// and each packet goes from the sharer over its own data channel to every
/// current watcher it serves, whatever carries that watcher's video.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() {
    RustLib.initMock(api: api);
    SoundService.enabled = false;
  });
  setUp(() {
    api.assigns.clear();
    api.offers.clear();
  });

  Future<_Rig> sharing({
    Map<String, ScreenShareService> direct = const {},
    Map<String, ScreenShareService> peerBranches = const {},
    Set<String> audioConnected = const {},
    bool shareAudio = true,
    bool startAudio = true,
  }) async {
    final dc = _Dc();
    final c = ProviderContainer(
      overrides: [
        voiceChannelProvider.overrideWith(_SharingRoom.new),
        webRtcProvider.overrideWith(() => dc),
        forwarderInfoProvider.overrideWith(_Vps.new),
      ],
    );
    addTearDown(c.dispose);
    final vc = c.read(voiceChannelProvider.notifier);
    // Runs before the dispose: no capture watchdog outlives the test.
    addTearDown(vc.stopScreenShare);
    final audio = _Audio();
    vc.debugShareAudioStarter = audio.start;
    vc.debugDirectLegFactory = _Leg.new;
    vc.debugAdoptCall(
      await _keyedMesh(),
      captureStream: _Capture(),
      forwarderIngests: peerBranches,
      peerForwarders: peerBranches.keys.toSet(),
      audioConnected: audioConnected,
    );
    vc.debugAdoptShare(
      originPeer: 'me-device',
      shareAudio: shareAudio,
      outgoingShares: direct,
    );
    if (shareAudio && startAudio) await vc.debugStartShareAudio();
    return _Rig(vc, audio, dc.fake);
  }

  Future<void> watch(
    VoiceChannelNotifier vc,
    String viewer, {
    bool want = true,
    String route = '',
    bool fwdCapable = false,
  }) => vc.handleSignal(
    viewer,
    'screen_watch',
    jsonEncode({'want': want, 'route': route, 'fwd_capable': fwdCapable}),
    'srv',
    'vc',
  );

  test('a viewer routed through the infra forwarder hears the share', () async {
    final r = await sharing();

    await watch(r.vc, 'v1', route: 'relay');

    expect(
      api.assigns['v1'],
      'fwd-vps',
      reason: 'the relay-routed viewer rides the forwarder',
    );
    r.audio.current.emit();
    expect(r.dc.sent, [
      'v1',
    ], reason: 'audio goes straight from the sharer to the viewer');
    expect(r.audio.started, 1, reason: 'one capture serves every viewer');
  });

  test('a share with audio starts its one capture when it goes live', () async {
    final r = await sharing(startAudio: false);
    expect(r.audio.started, 0);

    await r.vc.debugFinishShareStart(armRedirect: false, shareAudio: true);

    expect(r.audio.started, 1);
    await watch(r.vc, 'v1', route: 'relay');
    r.audio.current.emit();
    expect(r.dc.sent, ['v1']);
  });

  test('an unwatch or a leave is silent from the next packet', () async {
    final r = await sharing();
    await watch(r.vc, 'v1', route: 'relay');
    await watch(r.vc, 'v2', route: 'relay');
    r.audio.current.emit();
    expect(r.dc.sent, unorderedEquals(['v1', 'v2']));

    r.dc.sent.clear();
    await watch(r.vc, 'v1', want: false);
    r.audio.current.emit();
    expect(r.dc.sent, ['v2']);

    r.dc.sent.clear();
    await r.vc.onRemotePeerLeft('v2');
    r.audio.current.emit();
    expect(r.dc.sent, isEmpty);
  });

  test(
    'an unwatch is silent at once, even while another watch is routing',
    () async {
      final slow = _Leg();
      final r = await sharing(direct: {'v2': slow});
      await watch(r.vc, 'v2', route: 'direct');
      await watch(r.vc, 'v1', route: 'relay');

      // v2's re-sent watch is mid-flight (a native cap change).
      slow.capGate = Completer<bool>();
      final v2Routing = watch(r.vc, 'v2', route: 'direct');
      await pumpEventQueue();

      await watch(r.vc, 'v1', want: false);
      r.audio.current.emit();
      expect(r.dc.sent, ['v2'], reason: 'v1 stopped watching');

      slow.capGate!.complete(true);
      await v2Routing;
    },
  );

  test(
    'moving between a direct leg and a forwarder sends each packet once',
    () async {
      final r = await sharing(audioConnected: {'v1'});
      void heardOnce() {
        r.dc.sent.clear();
        r.audio.current.emit();
        expect(r.dc.sent, ['v1']);
      }

      await watch(r.vc, 'v1', route: 'direct');
      expect(api.offers, ['v1']);
      heardOnce();

      await watch(r.vc, 'v1', route: 'relay');
      expect(api.assigns['v1'], 'fwd-vps');
      // Both the direct leg and the branch serve v1 until the viewer retires
      // the direct one: still one copy of the audio.
      heardOnce();
      r.vc.debugDirectLeg('v1')!.onDisconnected!();
      await pumpEventQueue();
      expect(r.vc.debugDirectLeg('v1'), isNull);
      heardOnce();

      // The forwarder failed for them: back onto a fresh direct leg.
      await watch(r.vc, 'v1', route: 'direct_failed');
      expect(api.offers, ['v1', 'v1']);
      heardOnce();
      expect(r.audio.started, 1);
    },
  );

  test(
    'a promoted peer forwarder keeps hearing the share it now relays',
    () async {
      final head = _Leg();
      final r = await sharing(direct: {'h': head});
      await watch(r.vc, 'h', route: 'direct', fwdCapable: true);

      await watch(r.vc, 'v3', route: 'relay');

      expect(api.assigns['v3'], 'h', reason: 'h is promoted to serve v3');
      expect(head.closes, 1, reason: 'promotion closes the head\'s direct leg');
      r.audio.current.emit();
      expect(r.dc.sent, unorderedEquals(['h', 'v3']));
    },
  );

  test(
    'a peer forwarder that left stops hearing the share it still relays',
    () async {
      // Presence can flap while the head's ingest leg is alive, so its branch
      // stays; the head's own watch does not.
      final r = await sharing(peerBranches: {'h': _Leg()});
      await watch(r.vc, 'h', route: 'direct', fwdCapable: true);
      r.audio.current.emit();
      expect(r.dc.sent, ['h']);

      r.dc.sent.clear();
      await r.vc.onRemotePeerLeft('h');
      r.audio.current.emit();
      expect(r.dc.sent, isEmpty, reason: 'audio needs a current watch');
    },
  );

  test(
    'a watch landing while Stop sharing runs leaves no capture behind',
    () async {
      final r = await sharing(direct: {'v0': _Leg()});
      await watch(r.vc, 'v0', route: 'direct');
      final capture = r.audio.current;

      r.audio.stopGate = Completer<void>();
      final stopping = r.vc.stopScreenShare();
      await pumpEventQueue();
      capture.emit();
      // A re-sent watch (cap change, route reprobe) arrives mid-stop.
      await watch(r.vc, 'v0', route: 'direct');
      r.audio.stopGate!.complete();
      await stopping;
      await pumpEventQueue();

      expect(
        r.audio.running,
        isEmpty,
        reason: 'the share is stopped; no system audio may still be captured',
      );
      expect(r.audio.started, 1, reason: 'the late watch starts nothing');
      capture.emit();
      expect(r.dc.sent, isEmpty);
      expect(r.vc.state.shareWatchers, isEmpty);
    },
  );

  test('a watch landing while we leave the channel starts nothing', () async {
    final r = await sharing(direct: {'v0': _Leg()});
    await watch(r.vc, 'v0', route: 'direct');
    final capture = r.audio.current;

    r.audio.stopGate = Completer<void>();
    final leaving = r.vc.leaveChannel();
    await pumpEventQueue();
    capture.emit();
    await watch(r.vc, 'v1', route: 'relay');
    r.audio.stopGate!.complete();
    await leaving;
    await pumpEventQueue();

    expect(r.audio.running, isEmpty);
    expect(r.audio.started, 1);
    expect(api.assigns, isEmpty, reason: 'the late watch was not served');
    capture.emit();
    expect(r.dc.sent, isEmpty);
  });

  test('nothing is sent while our leave is on its way to the relay', () async {
    final r = await sharing(direct: {'v0': _Leg()});
    await watch(r.vc, 'v0', route: 'direct');

    api.leaveGate = Completer<void>();
    final leaving = r.vc.leaveChannel();
    await pumpEventQueue();
    // The capture is still up until the teardown runs; the room is not ours.
    r.audio.current.emit();
    expect(r.dc.sent, isEmpty);

    api.leaveGate!.complete();
    api.leaveGate = null;
    await leaving;
  });

  test(
    'a capture still starting when the share stops is stopped, not kept',
    () async {
      final r = await sharing(startAudio: false);
      r.audio.startGate = Completer<void>();
      final starting = r.vc.debugStartShareAudio();
      await pumpEventQueue();

      await r.vc.stopScreenShare();
      r.audio.startGate!.complete();
      await starting;

      expect(r.audio.started, 1);
      expect(r.audio.running, isEmpty);
    },
  );

  test('a new share never adopts the last one\'s capture', () async {
    final r = await sharing();
    final first = r.audio.current;
    await r.vc.stopScreenShare();
    expect(first.stopped, isTrue);

    // A new share, with new capture settings.
    r.vc.debugAdoptCall(await _keyedMesh(), captureStream: _Capture());
    r.vc.debugAdoptShare(originPeer: 'me-device', shareAudio: true);
    await r.vc.debugStartShareAudio();
    await watch(r.vc, 'v1', route: 'relay');

    expect(r.audio.started, 2);
    first.emit();
    expect(r.dc.sent, isEmpty, reason: 'the old capture speaks for nobody');
    r.audio.current.emit();
    expect(r.dc.sent, ['v1']);
  });

  testWidgets('a capture that dies is restarted, a bounded number of times', (
    tester,
  ) async {
    final r = await sharing();
    await watch(r.vc, 'v1', route: 'relay');

    for (final wait in [2, 4, 8]) {
      final dead = r.audio.current..die();
      await tester.pump(Duration(seconds: wait));
      await tester.pump();
      expect(r.audio.current, isNot(same(dead)), reason: 'restarted');
      expect(dead.stopped, isTrue);
      dead.emit();
      expect(r.dc.sent, isEmpty, reason: 'a dead capture speaks for nobody');
    }
    expect(r.audio.started, 4);
    r.audio.current.emit();
    expect(r.dc.sent, ['v1']);

    r.audio.current.die();
    await tester.pump(const Duration(seconds: 60));
    expect(r.audio.started, 4, reason: 'out of restarts');
    await r.vc.stopScreenShare();
  });

  testWidgets('a capture that dies long after it started is restarted too', (
    tester,
  ) async {
    final r = await sharing();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(r.audio.started, 1, reason: 'a live capture is left alone');

    r.audio.current.die();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(r.audio.started, 2);
    await r.vc.stopScreenShare();
  });

  testWidgets('a capture that dies after the share stopped stays down', (
    tester,
  ) async {
    final r = await sharing();
    r.audio.current.die();
    await r.vc.stopScreenShare();

    await tester.pump(const Duration(seconds: 30));

    expect(r.audio.started, 1);
  });

  test('a share without audio starts no capture', () async {
    final r = await sharing(shareAudio: false);
    await watch(r.vc, 'v1', route: 'relay');
    expect(api.assigns['v1'], 'fwd-vps');
    expect(r.audio.started, 0);
    expect(r.vc.shareAudioTargets, isEmpty);
  });

  group('a viewer', () {
    Future<VoiceChannelNotifier> watching() async {
      final c = ProviderContainer(
        overrides: [
          voiceChannelProvider.overrideWith(_WatchingRoom.new),
          webRtcProvider.overrideWith(_Dc.new),
          forwarderInfoProvider.overrideWith(_Vps.new),
        ],
      );
      addTearDown(c.dispose);
      final vc = c.read(voiceChannelProvider.notifier);
      vc.debugAdoptCall(await _keyedMesh());
      return vc;
    }

    test('plays a forwarded share\'s audio only from its sharer', () async {
      final vc = await watching();
      await vc.handleSignal(
        'bob',
        'screen_assign',
        jsonEncode({
          'origin': {'peer': 'bob', 'kind': 'screen', 'stream': 's'},
          'forwarder': 'fwd-vps',
        }),
        'srv',
        'vc',
      );

      expect(vc.acceptsShareAudioFrom('bob'), isTrue);
      expect(
        vc.acceptsShareAudioFrom('fwd-vps'),
        isFalse,
        reason: 'the forwarder never speaks for the share',
      );
      expect(vc.acceptsShareAudioFrom('mallory'), isFalse);
    });
  });

  group('the general data channel', () {
    ({_Dc dc, WebRtcNotifier n}) dialer() {
      final dc = _Dc();
      final c = ProviderContainer(
        overrides: [
          webRtcProvider.overrideWith(() => dc),
          forwarderInfoProvider.overrideWith(_Vps.new),
        ],
      );
      addTearDown(c.dispose);
      return (dc: dc, n: c.read(webRtcProvider.notifier));
    }

    test('is never dialled to the relay\'s media forwarder', () async {
      final d = dialer();
      await d.n.ensureConnection('fwd-vps');
      await d.n.ensureConnection('alice');
      expect(d.dc.fake.dialled, [
        'alice',
      ], reason: 'the forwarder is no friend or co-member; Rust refuses it');
    });
  });
}

class _Rig {
  _Rig(this.vc, this.audio, this.dc);
  final VoiceChannelNotifier vc;
  final _Audio audio;
  final _FakeWebRtc dc;
}

/// Records every share-audio capture the provider starts.
class _Audio {
  final all = <_Capt>[];
  Completer<void>? startGate;
  Completer<void>? stopGate;

  int get started => all.length;
  _Capt get current => all.last;
  Iterable<_Capt> get running => all.where((c) => !c.stopped);

  Future<ShareAudioCapture?> start(void Function(Uint8List) onPacket) async {
    final capture = _Capt(this, onPacket);
    all.add(capture);
    await startGate?.future;
    return capture;
  }
}

class _Capt implements ShareAudioCapture {
  _Capt(this.owner, this.onPacket);
  final _Audio owner;
  final void Function(Uint8List) onPacket;
  bool stopped = false;
  bool _alive = true;

  void emit() => onPacket(Uint8List(4));

  /// The capturer process exits on its own.
  void die() => _alive = false;

  @override
  bool get isActive => _alive && !stopped;

  @override
  Future<void> stop() async {
    await owner.stopGate?.future;
    stopped = true;
  }
}

class _Api implements RustLibApi {
  final assigns = <String, String>{};
  final offers = <String>[];
  Completer<void>? leaveGate;

  @override
  Future<void> crateApiNetworkVoiceChannelLeave({
    required String serverId,
    required String channelId,
  }) async {
    await leaveGate?.future;
  }

  @override
  Future<String?> crateApiNetworkGetLocalDevicePeerId() async => 'me-device';

  @override
  Future<void> crateApiNetworkVoiceChannelSendSignal({
    required String serverId,
    required String channelId,
    required String peerId,
    required String signalType,
    required String payload,
  }) async {
    if (signalType == 'screen_offer') offers.add(peerId);
    if (signalType == 'screen_assign') {
      assigns[peerId] = (jsonDecode(payload) as Map)['forwarder'] as String;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
      ? Future<void>.value()
      : super.noSuchMethod(invocation);
}

Future<VoiceChannelService> _keyedMesh() async {
  final mesh = _Mesh();
  final sframe = FrameCryptorService(factory: FakeFrameCryptorFactory());
  await sframe.init();
  await sframe.rotateKey(1, Uint8List(32));
  mesh.frameCryptor = sframe;
  return mesh;
}

class _SharingRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
    currentServerId: 'srv',
    currentChannelId: 'vc',
    currentChannelName: 'room',
    isScreenSharing: true,
  );
}

class _WatchingRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
    currentServerId: 'srv',
    currentChannelId: 'vc',
    currentChannelName: 'room',
    peerScreenSharing: {'bob': true},
    watchingScreenShares: {'bob'},
  );
}

class _Vps extends ForwarderInfoNotifier {
  @override
  ForwarderInfo build() => const ForwarderInfo(peerId: 'fwd-vps', online: true);
}

class _Dc extends WebRtcNotifier {
  final fake = _FakeWebRtc();
  @override
  WebRtcService get service => fake;
}

class _FakeWebRtc extends WebRtcService {
  _FakeWebRtc() : super(localPeerId: 'me-device', iceServers: const {});
  final sent = <String>[];
  final dialled = <String>[];

  @override
  void sendScreenAudio(String peerId, Uint8List payload) => sent.add(peerId);

  @override
  bool hasPeerChannel(String peerId) => false;

  @override
  Future<void> connectToPeer(String peerId) async => dialled.add(peerId);
}

class _Mesh extends VoiceChannelService {
  _Mesh() : super(localPeerId: 'me', iceServers: const {});

  @override
  Future<void> onPeerLeftMyChannel(String peerId) async {}

  @override
  Future<void> closeAll() async {}
}

/// A direct video leg; [capGate] holds a live cap change mid-flight.
class _Leg extends ScreenShareService {
  _Leg() : super(localPeerId: 'me', iceServers: const {});
  int closes = 0;
  Completer<bool>? capGate;

  @override
  Future<bool> updateResolutionCap(int maxWidth, int maxHeight) async =>
      capGate == null ? true : await capGate!.future;

  @override
  Future<String> createOfferFromStream(
    MediaStream stream, {
    int maxWidth = 1920,
    int maxHeight = 1080,
    int fps = 60,
    ScreenContentProfile profile = ScreenContentProfile.motion,
    bool simulcast = false,
  }) async => 'v=0';

  @override
  Future<void> close() async => closes++;
}

class _Capture extends MediaStream {
  _Capture() : super('capture', 'local');

  @override
  Future<void> dispose() async {}

  @override
  bool? get active => true;

  @override
  List<MediaStreamTrack> getTracks() => const [];

  @override
  List<MediaStreamTrack> getAudioTracks() => const [];

  @override
  List<MediaStreamTrack> getVideoTracks() => const [];

  @override
  Future<void> addTrack(MediaStreamTrack track, {bool addToNative = true}) =>
      throw UnimplementedError();

  @override
  Future<void> removeTrack(
    MediaStreamTrack track, {
    bool removeFromNative = true,
  }) => throw UnimplementedError();

  @override
  // ignore: deprecated_member_use
  Future<void> getMediaTracks() => throw UnimplementedError();
}

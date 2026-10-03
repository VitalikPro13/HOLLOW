import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack, RTCVideoRenderer;
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/voice_channel_service.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// Leaving a voice room closes its mesh exactly once, whatever else happens.
///
/// Rust announces our own leave while the leave call is still in flight, so
/// the forced-leave teardown used to run beside the leave's own. On the fleet
/// (session 31) the two tripped over each other's share cleanup and dropped
/// the mesh unclosed: its legs and watchdogs lived on and, after the rejoin,
/// asked the room to rebuild legs that were connected.
void main() {
  final api = _Api();
  setUpAll(() {
    RustLib.initMock(api: api);
    SoundService.enabled = false;
  });
  setUp(() {
    api.duringLeave = null;
    api.withdrawnWatches.clear();
    api.leftForwarderRooms.clear();
  });

  ({ProviderContainer c, VoiceChannelNotifier vc}) room() {
    final c = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(_Room.new),
      webRtcProvider.overrideWith(_NoDataChannels.new),
    ]);
    addTearDown(c.dispose);
    return (c: c, vc: c.read(voiceChannelProvider.notifier));
  }

  test('our own left event landing mid-leave still closes the mesh once',
      () async {
    final r = room();
    final mesh = _Mesh();
    final share = _Share();
    final capture = _Capture();
    r.vc.debugAdoptCall(mesh,
        incomingShares: {'sharer': share}, captureStream: capture);
    api.duringLeave = r.vc.onLocalLeft;

    await r.vc.leaveChannel();
    await pumpEventQueue(times: 100);

    expect(mesh.closes, 1, reason: 'the mesh must close, and only once');
    expect(share.closes, 1);
    expect(capture.disposes, 1,
        reason: 'a second dispose of a native stream fails, or frees twice');
    expect(api.withdrawnWatches, unorderedEquals(<String>['sharer', 's2']),
        reason: 'one teardown withdraws each watch once');
    expect(r.vc.service, isNull);
    expect(r.c.read(voiceChannelProvider).isInVoiceChannel, isFalse);
  });

  test('a repeated forced leave runs one teardown', () async {
    final r = room();
    final mesh = _Mesh();
    final share = _Share();
    final capture = _Capture();
    r.vc.debugAdoptCall(mesh,
        incomingShares: {'sharer': share}, captureStream: capture);

    r.vc.onLocalLeft();
    r.vc.onLocalLeft();
    await pumpEventQueue(times: 100);

    expect(mesh.closes, 1);
    expect(share.closes, 1);
    expect(capture.disposes, 1);
    expect(api.withdrawnWatches, unorderedEquals(<String>['sharer', 's2']));
    expect(r.vc.service, isNull);
  });

  test('each call gets its own teardown', () async {
    final r = room();
    final first = _Mesh();
    r.vc.debugAdoptCall(first);
    r.vc.onLocalLeft();
    await pumpEventQueue(times: 100);

    final second = _Mesh();
    r.vc.debugAdoptCall(second);
    r.vc.onLocalLeft();
    await pumpEventQueue(times: 100);

    expect(first.closes, 1);
    expect(second.closes, 1,
        reason: 'a finished teardown must not answer for the next call');
  });

  test('a cleanup step that throws still closes the rest and the mesh',
      () async {
    final r = room();
    final mesh = _Mesh();
    final broken = _Share(fails: true);
    final other = _Share();
    r.vc.debugAdoptCall(mesh,
        incomingShares: {'sharer': broken, 's2': other});

    await r.vc.leaveChannel();
    await pumpEventQueue(times: 100);

    expect(other.closes, 1, reason: 'one failed close must not strand the next');
    expect(mesh.closes, 1, reason: 'a dropped mesh keeps its legs alive');
    expect(r.vc.service, isNull);
  });

  test('a watch ending mid-teardown does not abort the share cleanup',
      () async {
    final r = room();
    final mesh = _Mesh();
    final s2 = _Share();
    final first = _Share(onClose: () => r.vc.stopWatchingScreenShare('s2'));
    r.vc.debugAdoptCall(mesh, incomingShares: {'sharer': first, 's2': s2});

    await r.vc.leaveChannel();
    await pumpEventQueue(times: 100);

    expect(s2.closes, 1);
    expect(mesh.closes, 1);
    final s = r.c.read(voiceChannelProvider);
    expect(s.peerScreenSharing, isEmpty,
        reason: 'the cleanup ran to its end and reset the share state');
    expect(s.watchingScreenShares, isEmpty);
  });

  test('a forwarder ingest leg that fails to close strands no other leg',
      () async {
    final r = room();
    final mesh = _Mesh();
    final first = _Share(fails: true);
    final second = _Share();
    r.vc.debugAdoptCall(mesh,
        forwarderIngests: {'fwd-1': first, 'fwd-2': second});

    await r.vc.leaveChannel();
    await pumpEventQueue(times: 100);

    expect(second.closes, 1);
    expect(api.leftForwarderRooms, containsAll(<String>['fwd-1', 'fwd-2']),
        reason: 'every forwarder learns we are gone');
    expect(mesh.closes, 1);
  });

  test('a camera self-view that fails to dispose skips no later phase',
      () async {
    final r = room();
    final mesh = _Mesh();
    final share = _Share();
    // Never initialized, so detaching its stream throws, as a renderer whose
    // native texture is already gone does.
    r.vc.debugAdoptCall(mesh,
        incomingShares: {'sharer': share}, cameraRenderer: RTCVideoRenderer());

    await r.vc.leaveChannel();
    await pumpEventQueue(times: 100);

    expect(share.closes, 1);
    expect(mesh.closes, 1);
    expect(r.vc.service, isNull);
  });
}

class _Api implements RustLibApi {
  void Function()? duringLeave;
  final leftForwarderRooms = <String>[];

  @override
  Future<void> crateApiNetworkVoiceChannelLeave(
      {required String serverId, required String channelId}) async {
    duringLeave?.call();
  }

  @override
  Future<void> crateApiNetworkLeaveForwarderRoom(
      {required String forwarderPeerId}) async {
    leftForwarderRooms.add(forwarderPeerId);
  }

  final withdrawnWatches = <String>[];

  @override
  Future<void> crateApiNetworkSetForwarderExpectation(
      {required String originPeer,
      required String kind,
      required bool active}) async {
    if (!active) withdrawnWatches.add(originPeer);
  }

  /// Every other call on the leave path is fire-and-forget `Future<void>`.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}

class _Room extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        currentServerId: 'srv',
        currentChannelId: 'vc',
        currentChannelName: 'room',
        peerScreenSharing: {'sharer': true, 's2': true},
        watchingScreenShares: {'sharer', 's2'},
      );
}

class _NoDataChannels extends WebRtcNotifier {
  @override
  WebRtcService get service => throw StateError('no data channels here');
}

class _Mesh extends VoiceChannelService {
  _Mesh() : super(localPeerId: 'me', iceServers: const {});
  int closes = 0;

  @override
  Future<void> closeAll() async {
    closes++;
    await Future<void>.delayed(Duration.zero);
  }
}

class _Share extends ScreenShareService {
  _Share({this.fails = false, this.onClose})
      : super(localPeerId: 'me', iceServers: const {});
  final bool fails;
  final void Function()? onClose;
  int closes = 0;

  @override
  Future<void> close() async {
    closes++;
    onClose?.call();
    await Future<void>.delayed(Duration.zero);
    if (fails) {
      throw PlatformException(code: 'MediaStreamDisposeFailed');
    }
  }
}

class _Capture extends MediaStream {
  _Capture() : super('capture', 'local');
  int disposes = 0;

  @override
  Future<void> dispose() async {
    disposes++;
    await Future<void>.delayed(Duration.zero);
  }

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
  Future<void> removeTrack(MediaStreamTrack track,
          {bool removeFromNative = true}) =>
      throw UnimplementedError();

  @override
  // ignore: deprecated_member_use
  Future<void> getMediaTracks() => throw UnimplementedError();
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack, RTCVideoRenderer;
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/services/desktop_capture_support.dart';
import 'package:hollow/src/core/services/realtime_session_flag.dart';
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
    api.screenStates.clear();
    api.deviceIdGate = null;
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

  test('a forced leave lets go of the voice session flag', () async {
    // A phone kept the flag after a kick, so it was never hidden or suspended
    // in the background again until the app restarted.
    RealtimeSessionFlag.reset();
    addTearDown(RealtimeSessionFlag.reset);
    final r = room();
    RealtimeSessionFlag.acquire('voice-channel');
    r.vc.debugAdoptCall(_Mesh());

    r.vc.onLocalLeft();
    await pumpEventQueue(times: 100);

    expect(RealtimeSessionFlag.isActive, isFalse);
  });

  test('a forced leave keeps a DM call flag', () async {
    RealtimeSessionFlag.reset();
    addTearDown(RealtimeSessionFlag.reset);
    final r = room();
    RealtimeSessionFlag.acquire('voice-channel');
    RealtimeSessionFlag.acquire('dm-call');

    r.vc.onLocalLeft();

    expect(RealtimeSessionFlag.holders, {'dm-call'});
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

  test('a share stopped while the voice redirect arms leaves nothing armed',
      () async {
    // The stop found nothing to disarm yet, and a redirect left armed keeps
    // every voice silent in hollow.exe with no share to end it.
    final c = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(_SharingRoom.new),
      webRtcProvider.overrideWith(_NoDataChannels.new),
    ]);
    addTearDown(c.dispose);
    final vc = c.read(voiceChannelProvider.notifier);
    final mesh = _Mesh();
    vc.debugAdoptCall(mesh);
    final held = mesh.redirectGate = Completer<void>();

    final arming = vc.debugArmVoiceRedirect();
    await pumpEventQueue();
    await vc.stopScreenShare();
    expect(c.read(voiceChannelProvider).isScreenSharing, isFalse);
    held.complete();
    await arming;

    expect(mesh.redirectStops, 1,
        reason: 'the redirect stayed armed after its share ended');
  });

  test('an arm that ends while the stop finishes leaves nothing armed',
      () async {
    final c = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(_SharingRoom.new),
      webRtcProvider.overrideWith(_NoDataChannels.new),
    ]);
    addTearDown(c.dispose);
    final vc = c.read(voiceChannelProvider.notifier);
    final mesh = _Mesh();
    final capture = _Capture();
    vc.debugAdoptCall(mesh, captureStream: capture);
    final armHeld = mesh.redirectGate = Completer<void>();
    final disposeHeld = capture.gate = Completer<void>();

    final arming = vc.debugArmVoiceRedirect();
    await pumpEventQueue();
    // The stop passes its disarm, then waits on the capture's dispose.
    final stopping = vc.stopScreenShare();
    await pumpEventQueue(times: 50);
    expect(c.read(voiceChannelProvider).isScreenSharing, isTrue);
    armHeld.complete();
    await arming;
    disposeHeld.complete();
    await stopping;

    expect(mesh.redirectStops, 1,
        reason: 'the redirect stayed armed after its share ended');
  });

  test('a share stopped while it starts announces no share', () async {
    // HOL-SEC-191 follow-up: the start resumed after its redirect armed and
    // told the room we share, with nothing captured and no stop to follow.
    final c = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(_SharingRoomWithPeer.new),
      webRtcProvider.overrideWith(_NoDataChannels.new),
    ]);
    addTearDown(c.dispose);
    final vc = c.read(voiceChannelProvider.notifier);
    final mesh = _Mesh();
    vc.debugAdoptCall(mesh);
    final held = mesh.redirectGate = Completer<void>();

    final starting = vc.debugFinishShareStart(armRedirect: true);
    await pumpEventQueue();
    await vc.stopScreenShare();
    held.complete();
    await starting;
    await pumpEventQueue();

    expect(api.screenStates, isNot(contains('{"enabled":true}')),
        reason: 'a share that ended during its start was announced');
    expect(api.screenStates.last, '{"enabled":false}');
    expect(c.read(voiceChannelProvider).isScreenSharing, isFalse);
    expect(mesh.redirectStops, 1);
  });

  test('a share that starts undisturbed is announced once', () async {
    final c = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(_SharingRoomWithPeer.new),
      webRtcProvider.overrideWith(_NoDataChannels.new),
    ]);
    addTearDown(c.dispose);
    final vc = c.read(voiceChannelProvider.notifier);
    final mesh = _Mesh();
    vc.debugAdoptCall(mesh);

    await vc.debugFinishShareStart(armRedirect: true);
    await pumpEventQueue();

    expect(api.screenStates, ['{"enabled":true}']);
    expect(mesh.redirectStops, 0);
    await vc.stopScreenShare();
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

  group('a share that starts while the room changes (HOL-SEC-195)', () {
    late Completer<MediaStream> picker;
    late int pickerOpens;
    late List<_Preview> previews;
    setUp(() {
      picker = Completer<MediaStream>();
      pickerOpens = 0;
      previews = [];
      ShareCapture.debugOpen = () {
        pickerOpens++;
        return picker.future;
      };
      ShareCapture.debugRenderer = () {
        final preview = _Preview();
        previews.add(preview);
        return preview;
      };
    });
    tearDown(() {
      ShareCapture.debugOpen = null;
      ShareCapture.debugRenderer = null;
    });

    ({ProviderContainer c, VoiceChannelNotifier vc, _Mesh mesh}) inRoom(
      VoiceChannelNotifier Function() room,
    ) {
      final c = ProviderContainer(
        overrides: [
          voiceChannelProvider.overrideWith(room),
          webRtcProvider.overrideWith(_NoDataChannels.new),
          callProvider.overrideWith(_NoCall.new),
        ],
      );
      addTearDown(c.dispose);
      final vc = c.read(voiceChannelProvider.notifier);
      final mesh = _Mesh();
      vc.debugAdoptCall(mesh);
      return (c: c, vc: vc, mesh: mesh);
    }

    Future<void> startAndLeave(
      Future<void> Function(VoiceChannelNotifier vc) leave,
    ) async {
      final r = inRoom(_RoomWithPeer.new);
      final capture = _Capture();
      final starting = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      expect(pickerOpens, 1);
      await leave(r.vc);
      await pumpEventQueue(times: 100);
      picker.complete(capture);
      await starting;
      await pumpEventQueue(times: 20);

      expect(capture.disposes, 1, reason: 'the capture outlived its room');
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isFalse);
      expect(r.vc.localScreenShareRenderer, isNull);
      expect(
        previews,
        isEmpty,
        reason: 'a preview was opened for a share its room had left',
      );
      expect(
        api.screenStates,
        isNot(contains('{"enabled":true}')),
        reason: 'a room was told of a share started for another',
      );

      // The next room hears of no share and serves no watch.
      unawaited(r.vc.onLocalJoined('srv', 'vc2').catchError((_) {}));
      await pumpEventQueue(times: 20);
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isFalse);
    }

    test(
      'a leave during the picker leaves no share for the next room',
      () async {
        await startAndLeave((vc) => vc.leaveChannel());
      },
    );

    test('a kick during the picker leaves no share', () async {
      await startAndLeave((vc) async => vc.onLocalLeft());
    });

    test('a picker that returns mid-leave leaves no share', () async {
      final r = inRoom(_RoomWithPeer.new);
      final capture = _Capture();
      final starting = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      api.duringLeave = () => picker.complete(capture);
      final leaving = r.vc.leaveChannel();
      await starting;
      await leaving;
      await pumpEventQueue(times: 100);

      expect(capture.disposes, 1);
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isFalse);
      expect(api.screenStates, isNot(contains('{"enabled":true}')));
    });

    test('a stop during the picker cancels the share', () async {
      final r = inRoom(_RoomWithPeer.new);
      final capture = _Capture();
      final starting = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      await r.vc.stopScreenShare();
      picker.complete(capture);
      await starting;

      expect(capture.disposes, 1);
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isFalse);
      expect(api.screenStates, isNot(contains('{"enabled":true}')));
    });

    test('a second start while the picker is up is refused', () async {
      final r = inRoom(_RoomWithPeer.new);
      final first = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      await r.vc.startScreenShare('screen:1', 1920, 1080, 30);
      expect(pickerOpens, 1, reason: 'two pickers race for one share');
      picker.complete(_Capture());
      await first;
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isTrue);
      await r.vc.stopScreenShare();
    });

    test('a join from outside any room never inherits a share', () async {
      final r = inRoom(_LeftoverShare.new);
      final capture = _Capture();
      r.vc.debugAdoptCall(r.mesh, captureStream: capture);

      unawaited(r.vc.onLocalJoined('srv', 'vc2').catchError((_) {}));
      await pumpEventQueue(times: 20);

      expect(capture.disposes, 1);
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isFalse);
    });

    test('a re-share during an old arm leaves only its own redirect', () async {
      final r = inRoom(_RoomWithPeer.new);
      r.vc.debugArmEveryShare = true;
      ShareCapture.debugOpen = () async => _Capture();
      final held = r.mesh.redirectGate = Completer<void>();

      final old = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isTrue);
      await r.vc.stopScreenShare();
      final fresh = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      held.complete();
      await old;
      await fresh;
      await pumpEventQueue(times: 20);

      expect(
        r.mesh.redirectStops,
        1,
        reason: 'the old share left its redirect armed',
      );
      expect(r.mesh.redirectLog, [
        'start',
        'stop',
        'start',
      ], reason: "the old arm's stop ended the new share's redirect in native");
      expect(
        r.vc.debugVoiceRedirectArmed,
        isTrue,
        reason: 'the new share lost its own redirect',
      );
      await r.vc.stopScreenShare();
      expect(r.mesh.redirectStops, 2);
      expect(r.vc.debugVoiceRedirectArmed, isFalse);
    });

    test(
      'a share stopped while it waits for an older arm arms nothing',
      () async {
        final r = inRoom(_RoomWithPeer.new);
        r.vc.debugArmEveryShare = true;
        ShareCapture.debugOpen = () async => _Capture();
        final held = r.mesh.redirectGate = Completer<void>();

        final old = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
        await pumpEventQueue();
        await r.vc.stopScreenShare();
        final fresh = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
        await pumpEventQueue();
        await r.vc.stopScreenShare();
        held.complete();
        await old;
        await fresh;
        await pumpEventQueue(times: 20);

        expect(r.mesh.redirectLog, ['start', 'stop']);
        expect(r.vc.debugVoiceRedirectArmed, isFalse);
      },
    );

    test('a leave before the picker opens opens no picker', () async {
      final r = inRoom(_RoomWithPeer.new);
      final gate = api.deviceIdGate = Completer<void>();
      final starting = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      await r.vc.leaveChannel();
      await pumpEventQueue(times: 100);
      gate.complete();
      await starting;

      expect(pickerOpens, 0);
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isFalse);
    });

    test('a leave while the preview opens leaves no share', () async {
      final r = inRoom(_RoomWithPeer.new);
      final capture = _Capture();
      final opening = Completer<void>();
      final preview = _Preview(opening);
      ShareCapture.debugRenderer = () => preview;
      final starting = r.vc.startScreenShare('screen:0', 1920, 1080, 30);
      await pumpEventQueue();
      picker.complete(capture);
      await pumpEventQueue();
      expect(preview.initializes, 1);
      await r.vc.leaveChannel();
      await pumpEventQueue(times: 100);
      opening.complete();
      await starting;
      await pumpEventQueue(times: 20);

      expect(capture.disposes, 1);
      expect(preview.disposes, 1);
      expect(r.c.read(voiceChannelProvider).isScreenSharing, isFalse);
      expect(r.vc.localScreenShareRenderer, isNull);
      expect(api.screenStates, isNot(contains('{"enabled":true}')));
    });
  });
}

class _NoCall extends CallNotifier {
  @override
  CallState build() => const CallState();
}

class _RoomWithPeer extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
    currentServerId: 'srv',
    currentChannelId: 'vc',
    currentChannelName: 'room',
    participants: {
      'srv': {
        'vc': {'peer'},
      },
    },
  );
}

/// Out of every room, with a share a start left behind.
class _LeftoverShare extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(isScreenSharing: true);
}

class _Preview extends RTCVideoRenderer {
  _Preview([this.gate]);
  final Completer<void>? gate;
  int initializes = 0;
  int disposes = 0;

  @override
  Future<void> initialize() async {
    initializes++;
    await gate?.future;
  }

  @override
  set srcObject(MediaStream? stream) {}

  @override
  Future<void> dispose() async {
    disposes++;
    await super.dispose();
  }
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
  Future<String?> crateApiNetworkGetLocalDevicePeerId() async {
    await deviceIdGate?.future;
    return 'me-device';
  }

  Completer<void>? deviceIdGate;

  @override
  Future<void> crateApiNetworkLeaveForwarderRoom(
      {required String forwarderPeerId}) async {
    leftForwarderRooms.add(forwarderPeerId);
  }

  final withdrawnWatches = <String>[];
  final screenStates = <String>[];

  @override
  Future<void> crateApiNetworkVoiceChannelSendSignal(
      {required String serverId,
      required String channelId,
      required String peerId,
      required String signalType,
      required String payload}) async {
    if (signalType == 'screen_state') screenStates.add(payload);
  }

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

class _SharingRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        currentServerId: 'srv',
        currentChannelId: 'vc',
        currentChannelName: 'room',
        isScreenSharing: true,
      );
}

class _SharingRoomWithPeer extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        currentServerId: 'srv',
        currentChannelId: 'vc',
        currentChannelName: 'room',
        isScreenSharing: true,
        participants: {
          'srv': {
            'vc': {'peer'}
          }
        },
      );
}

class _NoDataChannels extends WebRtcNotifier {
  @override
  WebRtcService get service => throw StateError('no data channels here');
}

class _Mesh extends VoiceChannelService {
  _Mesh() : super(localPeerId: 'me', iceServers: const {});
  int closes = 0;
  Completer<void>? redirectGate;
  int redirectStarts = 0;
  int redirectStops = 0;

  /// Native redirect calls in the order they are made.
  final redirectLog = <String>[];

  @override
  Future<int> startVoiceRedirect() async {
    redirectLog.add('start');
    final pid = 4242 + redirectStarts++;
    await redirectGate?.future;
    return pid;
  }

  @override
  Future<void> stopVoiceRedirect() async {
    redirectLog.add('stop');
    redirectStops++;
  }

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
  Completer<void>? gate;

  @override
  Future<void> dispose() async {
    disposes++;
    await gate?.future;
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

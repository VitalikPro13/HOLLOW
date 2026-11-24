/// The OS call mirror (#154, DESIGN_OS_CALLS rev 3): which session the OS
/// sees, the order native hears about it, OS actions through the app's own
/// paths, the hold guard, the fallback and reset paths, and the title rule.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hidden_notification.dart';
import 'package:hollow/src/core/models/call_record.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/mute_deafen.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/audio_route_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/os_call_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/audio_route.dart';
import 'package:hollow/src/core/services/os_call_avatar.dart';
import 'package:hollow/src/core/services/os_call_service.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';

// --- fakes -------------------------------------------------------------------

class _Native implements OsCallChannel {
  final calls = <(String, Map<String, Object?>)>[];
  Future<Object?> Function(String method, Map<Object?, Object?> args)? handler;

  /// What `begin` answers; a throw stands in for a broken native side.
  Object? Function(Map<String, Object?> args) onBegin = (_) => {'ok': true};

  /// A native side slow to answer [holdMethod] until [hold] completes.
  String? holdMethod;
  Completer<void>? hold;

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? args]) async {
    final a = args ?? const <String, Object?>{};
    calls.add((method, a));
    if (method == holdMethod) await hold?.future;
    if (method == 'begin') return onBegin(a);
    if (method == 'available') return true;
    return null;
  }

  @override
  void setHandler(
          Future<Object?> Function(String, Map<Object?, Object?>)? handler) =>
      this.handler = handler;

  Future<void> send(String method, [Map<String, Object?> args = const {}]) =>
      handler!(method, args);

  List<String> get methods =>
      [for (final c in calls) if (c.$1 != 'available') c.$1];
  List<Map<String, Object?>> of(String method) =>
      [for (final c in calls) if (c.$1 == method) c.$2];
  Map<String, Object?> lastOf(String method) => of(method).last;
  void clear() => calls.clear();
}

class _Call extends CallNotifier {
  CallState seed;
  _Call(this.seed);
  int ends = 0, mutes = 0, deafens = 0, speakers = 0;
  bool refuseMute = false;
  CallEndCause? cause;

  @override
  CallState build() => seed;

  void set(CallState s) => state = s;

  @override
  CallEndCause? get lastEndCause => cause;

  @override
  Future<void> endCall() async {
    ends++;
    cause = CallEndCause.localHangup;
    state = const CallState();
  }

  @override
  void toggleMute() {
    mutes++;
    if (refuseMute || state.status != CallStatus.active) return;
    _apply(_model.tapMute());
  }

  @override
  void toggleDeafen() {
    deafens++;
    if (state.status != CallStatus.active) return;
    _apply(_model.tapDeafen());
  }

  @override
  void setSpeaker(bool on) {
    speakers++;
    if (state.status == CallStatus.idle) return;
    state = state.copyWith(isSpeakerOn: on);
    (ref.read(audioRouteProvider.notifier) as _Routes).platformSpeaker(on);
  }

  // The real notifiers' rule (test/mute_deafen_test.dart pins it there).
  bool _before = false;
  MuteDeafen get _model => MuteDeafen(
      muted: state.isMuted,
      deafened: state.isDeafened,
      mutedBeforeDeafen: _before);
  void _apply(MuteDeafen next) {
    _before = next.mutedBeforeDeafen;
    state = state.copyWith(isMuted: next.muted, isDeafened: next.deafened);
  }
}

class _Voice extends VoiceChannelNotifier {
  VoiceChannelState seed;
  _Voice(this.seed);
  int leaves = 0, mutes = 0, deafens = 0, speakers = 0;

  @override
  VoiceChannelState build() => seed;

  void set(VoiceChannelState s) => state = s;

  @override
  Future<void> leaveChannel() async {
    leaves++;
    state = const VoiceChannelState();
  }

  @override
  void toggleMute() {
    mutes++;
    _apply(_model.tapMute());
  }

  @override
  void toggleDeafen() {
    deafens++;
    _apply(_model.tapDeafen());
  }

  @override
  void setSpeaker(bool on) {
    speakers++;
    state = state.copyWith(isSpeakerOn: on);
    (ref.read(audioRouteProvider.notifier) as _Routes).platformSpeaker(on);
  }

  bool _before = false;
  MuteDeafen get _model => MuteDeafen(
      muted: state.isMuted,
      deafened: state.isDeafened,
      mutedBeforeDeafen: _before);
  void _apply(MuteDeafen next) {
    _before = next.mutedBeforeDeafen;
    state = state.copyWith(isMuted: next.muted, isDeafened: next.deafened);
  }
}

class _Conference extends ConferenceNotifier {
  ConferenceState seed;
  _Conference(this.seed);
  int leaves = 0, ends = 0;

  @override
  ConferenceState build() => seed;

  @override
  Future<void> leaveMeeting() async => leaves++;

  @override
  Future<void> endMeeting() async => ends++;
}

/// The route audio is on, as the platform reports it: a connected headset
/// keeps the audio whatever the loudspeaker asks.
class _Routes extends AudioRouteNotifier {
  final AudioRouteKind? seed;
  final List<AudioRoute> attached;
  _Routes(this.seed, [this.attached = const []]);

  @override
  AudioRouteState build() =>
      AudioRouteState(routes: attached, activeKind: seed, loaded: true);

  void set(AudioRouteKind? kind) => state =
      AudioRouteState(routes: attached, activeKind: kind, loaded: true);

  void platformSpeaker(bool on) {
    if (state.activeKind?.isExternal ?? false) return;
    set(on ? AudioRouteKind.speaker : AudioRouteKind.earpiece);
  }
}

class _Lock extends AppLockedNotifier {
  @override
  bool build() => false;
  void set(bool v) => state = v;
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        'ada': _profile('ada', 'Ada'),
      };
  void rename(String id, String name) =>
      state = {...state, id: _profile(id, name)};
}

class _Speaker extends StartCallsOnSpeakerNotifier {
  final bool on;
  _Speaker([this.on = true]);
  @override
  Future<bool> build() async => on;
}

storage_api.UserProfile _profile(String id, String name) =>
    storage_api.UserProfile(
      peerId: id,
      displayName: name,
      status: '',
      aboutMe: '',
      updatedAt: 0,
      twitchUsername: '',
      showcaseBoard: '',
      avatarFrame: '',
      avatarAnim: '',
      bannerAnim: '',
      supportCreds: '',
      nameColor: '',
    );

const _noPassword = identity_api.ProtectionStatus(
    isEncrypted: true,
    hasPassword: false,
    hasOsKeychain: true,
    osKeychainAvailable: true);

const _withPassword = identity_api.ProtectionStatus(
    isEncrypted: true,
    hasPassword: true,
    hasOsKeychain: false,
    osKeychainAvailable: true);

const _confId = 'c0ffee';

/// What the avatar source hands the service for Ada: 2 x 2 pixels.
final _adaFace = OsCallAvatar(2, Uint8List.fromList(List.filled(16, 7)));

CallState _outgoing(String id, {bool video = false}) => CallState(
    status: CallStatus.ringing,
    direction: CallDirection.outgoing,
    peerId: 'ada',
    callId: id,
    isVideoCall: video);

/// A call we placed that the other side answered: media is coming up.
CallState _placed(String id, {bool video = false}) =>
    _outgoing(id, video: video).copyWith(status: CallStatus.connecting);

CallState _incoming(String id) => CallState(
    status: CallStatus.ringing,
    direction: CallDirection.incoming,
    peerId: 'ada',
    callId: id);

VoiceChannelState _room({bool muted = false, bool speaker = false}) =>
    VoiceChannelState(
        currentServerId: 's1',
        currentChannelId: 'ch1',
        currentChannelName: 'Lounge',
        isMuted: muted,
        isSpeakerOn: speaker);

VoiceChannelState _meetingSeat() => VoiceChannelState(
    currentServerId: conferenceServerId(_confId),
    currentChannelId: kConferenceChannelId,
    currentChannelName: 'Meeting');

final _uuidShape = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

// --- harness -----------------------------------------------------------------

class _Rig {
  final ProviderContainer c;
  final _Native native;
  final _Call call;
  final _Voice voice;
  final _Conference conference;
  final _Lock lock;
  final _Profiles profiles;
  final _Routes routes;
  _Rig(this.c, this.native, this.call, this.voice, this.conference, this.lock,
      this.profiles, this.routes);

  OsCallService get service => c.read(osCallServiceProvider)!;

  /// Lets the provider listeners fire and the queue drain.
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await pumpEventQueue();
      await service.settled;
    }
  }
}

Future<_Rig> _rig({
  CallState call = const CallState(),
  VoiceChannelState voice = const VoiceChannelState(),
  ConferenceState conference = const ConferenceState(),
  identity_api.ProtectionStatus protection = _noPassword,
  Set<String> ageHidden = const {},
  bool startOnSpeaker = true,
  OsCallAvatarSource? faces,
  AudioRouteKind? route,
}) async {
  final native = _Native();
  final callN = _Call(call);
  final voiceN = _Voice(voice);
  final confN = _Conference(conference);
  final lock = _Lock();
  final profiles = _Profiles();
  final routes = _Routes(route);
  final c = ProviderContainer(overrides: [
    audioRouteProvider.overrideWith(() => routes),
    osCallChannelProvider.overrideWithValue(native),
    callProvider.overrideWith(() => callN),
    voiceChannelProvider.overrideWith(() => voiceN),
    conferenceProvider.overrideWith(() => confN),
    appLockedProvider.overrideWith(() => lock),
    profileProvider.overrideWith(() => profiles),
    identityProtectionProvider.overrideWith((ref) async => protection),
    startCallsOnSpeakerProvider.overrideWith(() => _Speaker(startOnSpeaker)),
    osCallAvatarSourceProvider
        .overrideWithValue(faces ?? (_) async => _adaFace),
    keptServersProvider.overrideWithValue(
        {'s1': const ServerInfo(serverId: 's1', name: 'Den')}),
    serverAgeHiddenProvider
        .overrideWith((ref, serverId) => ageHidden.contains(serverId)),
  ]);
  addTearDown(c.dispose);
  await c.read(identityProtectionProvider.future);
  await c.read(startCallsOnSpeakerProvider.future);
  final rig = _Rig(c, native, callN, voiceN, confN, lock, profiles, routes);
  rig.service; // mount
  await rig.settle();
  return rig;
}

void main() {
  final logs = <String>[];
  setUp(() {
    debugOsCallPlatform = true;
    logs.clear();
    OsCallService.log = logs.add;
  });
  tearDown(() => debugOsCallPlatform = null);

  group('derivation', () {
    OsSession? derive(
            {CallState call = const CallState(),
            VoiceChannelState voice = const VoiceChannelState(),
            ConferenceState conference = const ConferenceState(),
            AudioRouteKind? route}) =>
        deriveOsSession(
            call: call, voice: voice, conference: conference, route: route);

    test('nothing live is no session, and an incoming ring is never one', () {
      expect(derive(), isNull);
      expect(derive(call: _incoming('c1')), isNull);
    });

    // Ringing out under CallKit plays the ringback as call audio, at the ear,
    // so a call we place reaches the OS once answered.
    test('a placed call is no session while it rings, one once answered', () {
      expect(derive(call: _outgoing('c1')), isNull);
      final answered = derive(call: _placed('c1'))!;
      expect(answered.key, 'dm:c1');
      expect(answered.live, isFalse);
      expect(answered.outgoing, isTrue);
      final active = derive(
          call: _outgoing('c1').copyWith(status: CallStatus.active))!;
      expect(active.key, 'dm:c1');
      expect(active.live, isTrue);
    });

    test('an accepted call is a session from connecting', () {
      final s = derive(
          call: _incoming('c1').copyWith(status: CallStatus.connecting))!;
      expect(s.key, 'dm:c1');
      expect(s.live, isFalse);
      expect(s.outgoing, isFalse);
    });

    test('a DM call goes before the room it is leaving', () {
      final s = derive(
          call: _incoming('c1').copyWith(status: CallStatus.connecting),
          voice: _room())!;
      expect(s.key, 'dm:c1');
    });

    test('a room and a meeting have their own keys', () {
      expect(derive(voice: _room())!.key, 'vc:s1/ch1');
      expect(derive(voice: _room())!.kind, OsCallKind.room);
      final meeting = derive(
          voice: _meetingSeat(),
          conference: const ConferenceState(
              activeConfId: _confId,
              lobbyStatus: ConferenceLobbyStatus.inCall))!;
      expect(meeting.key, 'meet:$_confId');
      expect(meeting.kind, OsCallKind.meeting);
    });

    test('video follows a camera or share on either side', () {
      expect(derive(voice: _room())!.video, isFalse);
      expect(
          derive(voice: _room().copyWith(peerCameraOn: {'p': true}))!.video,
          isTrue);
      expect(derive(call: _placed('c1', video: true))!.video, isTrue);
      expect(
          derive(
                  call: _placed('c1')
                      .copyWith(status: CallStatus.active, remoteScreenSharing: true))!
              .video,
          isTrue);
    });

    // Hands-free (isSpeakerOn) is true for a headset too; the notification's
    // Speaker says only whether the loudspeaker plays.
    test('speaker is the loudspeaker route, never hands-free', () {
      final call = _placed('c1').copyWith(isSpeakerOn: true);
      expect(derive(call: call, route: AudioRouteKind.bluetooth)!.speaker,
          isFalse);
      expect(derive(call: call, route: AudioRouteKind.wired)!.speaker, isFalse);
      expect(derive(call: call)!.speaker, isFalse, reason: 'route unknown');
      expect(
          derive(call: _placed('c1'), route: AudioRouteKind.speaker)!.speaker,
          isTrue);
      final room = _room(speaker: true);
      expect(derive(voice: room, route: AudioRouteKind.bluetooth)!.speaker,
          isFalse);
      expect(
          derive(voice: room, route: AudioRouteKind.speaker)!.speaker, isTrue);
      expect(derive(voice: _room(), route: AudioRouteKind.earpiece)!.speaker,
          isFalse);
    });

    test('a desktop builds nothing', () async {
      debugOsCallPlatform = false;
      final c = ProviderContainer(overrides: [
        callProvider.overrideWith(() => _Call(_placed('c1'))),
        voiceChannelProvider.overrideWith(() => _Voice(_room())),
        conferenceProvider.overrideWith(() => _Conference(const ConferenceState())),
      ]);
      addTearDown(c.dispose);
      expect(c.read(osSessionProvider), isNull);
      expect(c.read(osCallServiceProvider), isNull);
    });
  });

  group('begin, connected, end', () {
    test('a joined room begins at once, named and connected', () async {
      final r = await _rig();
      r.voice.set(_room());
      await r.settle();
      expect(r.native.methods, ['begin', 'connected']);
      final begin = r.native.lastOf('begin');
      expect(begin['kind'], 'room');
      expect(begin['title'], 'Lounge · Den');
      expect(begin['loud'], isTrue);
      expect(begin['outgoing'], isTrue);
      expect(begin['uuid'], matches(_uuidShape));
      expect(begin['live'], [begin['uuid']]);
      expect(r.native.lastOf('connected')['uuid'], begin['uuid']);
    });

    test('the system\'s id for a call is a fresh random uuid, never an id',
        () async {
      final r = await _rig();
      r.call.set(_placed('c1'));
      await r.settle();
      final first = r.native.lastOf('begin')['uuid'] as String;
      r.call.set(const CallState());
      await r.settle();
      r.call.set(_placed('c1'));
      await r.settle();
      final second = r.native.lastOf('begin')['uuid'] as String;
      expect(first, matches(_uuidShape));
      expect(second, matches(_uuidShape));
      expect(second, isNot(first), reason: 'the same call id, a new uuid');
    });

    test('a placed call begins when answered, not while it rings', () async {
      final r = await _rig();
      r.call.set(_outgoing('c1'));
      await r.settle();
      expect(r.native.methods, isEmpty);
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.methods, ['begin']);
      expect(r.native.lastOf('begin')['title'], 'Ada');
      expect(r.native.lastOf('begin')['kind'], 'dm');
      r.call.set(_outgoing('c1').copyWith(status: CallStatus.active));
      await r.settle();
      expect(r.native.methods, ['begin', 'connected']);
    });

    test('accepting a call from a room ends the room before the call begins',
        () async {
      final r = await _rig(voice: _room(), call: _incoming('c1'));
      final roomUuid = r.native.lastOf('begin')['uuid'];
      r.native.clear();
      // acceptCall: connecting first, the room's leave after.
      r.call.set(_incoming('c1').copyWith(status: CallStatus.connecting));
      r.voice.set(const VoiceChannelState());
      await r.settle();
      expect(r.native.methods, ['end', 'begin']);
      expect(r.native.lastOf('end')['uuid'], roomUuid);
      final begin = r.native.lastOf('begin');
      expect(begin['kind'], 'dm');
      expect(begin['uuid'], isNot(roomUuid));
      expect(begin['live'], [begin['uuid']],
          reason: 'the room ended first, so native holds only the call');
    });

    test('answered elsewhere right after our accept leaves no OS call',
        () async {
      final r = await _rig(call: _incoming('c1'));
      expect(r.native.methods, isEmpty, reason: 'a ring is never mirrored');
      r.call.set(_incoming('c1').copyWith(status: CallStatus.connecting));
      await r.settle();
      r.call.cause = CallEndCause.answeredElsewhere;
      r.call.set(const CallState());
      await r.settle();
      expect(r.native.methods, ['begin', 'end']);
      expect(r.native.lastOf('end')['uuid'], r.native.lastOf('begin')['uuid']);
      expect(r.service.liveUuid, isNull);
    });

    test('the same race inside one beat begins nothing', () async {
      final r = await _rig(call: _incoming('c1'));
      r.call.set(_incoming('c1').copyWith(status: CallStatus.connecting));
      r.call.set(const CallState());
      await r.settle();
      expect(r.native.of('begin').length, r.native.of('end').length);
      expect(r.service.liveUuid, isNull);
    });

    test('a media rebuild keeps the one OS call', () async {
      final r = await _rig(
          call: _outgoing('c1').copyWith(status: CallStatus.active));
      r.native.clear();
      r.call.set(r.call.state.copyWith(status: CallStatus.connecting));
      await r.settle();
      r.call.set(r.call.state.copyWith(status: CallStatus.active));
      await r.settle();
      expect(r.native.methods, isEmpty);
    });

    test('a meeting ending in the app ends the OS call', () async {
      final r = await _rig(
          voice: _meetingSeat(),
          conference: const ConferenceState(
              activeConfId: _confId,
              lobbyStatus: ConferenceLobbyStatus.inCall));
      expect(r.native.lastOf('begin')['kind'], 'meeting');
      r.voice.set(const VoiceChannelState());
      await r.settle();
      expect(r.native.lastOf('end')['uuid'], r.native.lastOf('begin')['uuid']);
      expect(r.native.lastOf('end')['reason'], 'local');
    });

    test('a remote end and a lost link say so', () async {
      final r = await _rig(
          call: _outgoing('c1').copyWith(status: CallStatus.active));
      r.call.cause = CallEndCause.remoteEnd;
      r.call.set(const CallState());
      await r.settle();
      expect(r.native.lastOf('end')['reason'], 'remote');
      r.call.set(_outgoing('c2').copyWith(status: CallStatus.active));
      await r.settle();
      r.call.cause = CallEndCause.linkLost;
      r.call.set(const CallState());
      await r.settle();
      expect(r.native.lastOf('end')['reason'], 'failed');
    });

    test('a native side that throws never stops the call or the next one',
        () async {
      final r = await _rig();
      r.native.onBegin = (_) => throw PlatformException(code: 'boom');
      r.voice.set(_room());
      await r.settle();
      final uuid = r.native.lastOf('begin')['uuid'];
      r.voice.set(const VoiceChannelState());
      await r.settle();
      expect(r.native.lastOf('end')['uuid'], uuid);
      expect(logs.any((l) => l.contains('begin failed')), isTrue);
    });
  });

  group('start route', () {
    test('a call we place starts where the setting says', () async {
      final r = await _rig(startOnSpeaker: false);
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.lastOf('begin')['loud'], isFalse);
    });

    test('an accepted call starts where the setting says', () async {
      final r = await _rig(startOnSpeaker: false, call: _incoming('c1'));
      r.call.set(_incoming('c1').copyWith(status: CallStatus.connecting));
      await r.settle();
      expect(r.native.lastOf('begin')['loud'], isFalse);
    });

    test('a reset of an answered call keeps the setting', () async {
      final r = await _rig(
          startOnSpeaker: false,
          call: _outgoing('c1').copyWith(status: CallStatus.active));
      expect(r.native.lastOf('begin')['loud'], isFalse);
      await r.native.send('osReset');
      await r.settle();
      expect(r.native.lastOf('begin')['loud'], isFalse);
    });
  });

  group('mute', () {
    test('the app mute reaches the OS', () async {
      final r = await _rig(voice: _room());
      r.native.clear();
      r.voice.set(_room(muted: true));
      await r.settle();
      expect(r.native.methods, ['setMuted']);
      expect(r.native.lastOf('setMuted')['muted'], isTrue);
    });

    test('an OS mute goes through the app toggle, then the OS hears the truth',
        () async {
      final r = await _rig(voice: _room());
      final uuid = r.service.liveUuid;
      r.native.clear();
      await r.native.send('osMute', {'uuid': uuid, 'muted': true});
      await r.settle();
      expect(r.voice.mutes, 1);
      expect(r.voice.state.isMuted, isTrue);
      expect(r.native.of('setMuted').last['muted'], isTrue);
    });

    test('our own echo toggles nothing and sends nothing', () async {
      final r = await _rig(voice: _room(muted: true));
      final uuid = r.service.liveUuid;
      r.native.clear();
      await r.native.send('osMute', {'uuid': uuid, 'muted': true});
      await r.settle();
      expect(r.voice.mutes, 0);
      expect(r.native.methods, isEmpty);
    });

    test('a refused mute puts the OS back to the truth', () async {
      final r = await _rig(call: _placed('c1'));
      final uuid = r.service.liveUuid;
      r.native.clear();
      // Answered, media not up yet: the app refuses a mute until connected.
      await r.native.send('osMute', {'uuid': uuid, 'muted': true});
      await r.settle();
      expect(r.call.mutes, 1);
      expect(r.native.methods, ['setMuted']);
      expect(r.native.lastOf('setMuted')['muted'], isFalse);
    });

    test('an action for a uuid we do not hold does nothing', () async {
      final r = await _rig(voice: _room());
      await r.native.send('osMute', {'uuid': 'stranger', 'muted': true});
      await r.native.send('osEnd', {'uuid': 'stranger'});
      await r.settle();
      expect(r.voice.mutes, 0);
      expect(r.voice.leaves, 0);
    });
  });

  group('OS hang-up', () {
    test('a DM call hangs up through endCall, once', () async {
      final r = await _rig(
          call: _outgoing('c1').copyWith(status: CallStatus.active));
      final uuid = r.service.liveUuid;
      await r.native.send('osEnd', {'uuid': uuid});
      await r.settle();
      await r.native.send('osEnd', {'uuid': uuid});
      await r.settle();
      expect(r.call.ends, 1);
      expect(r.native.of('end').length, 1, reason: 'end is sent once per uuid');
    });

    test('a room is left', () async {
      final r = await _rig(voice: _room());
      await r.native.send('osEnd', {'uuid': r.service.liveUuid});
      await r.settle();
      expect(r.voice.leaves, 1);
      expect(r.service.liveUuid, isNull);
    });

    test('a meeting guest leaves the meeting, never a bare voice leave',
        () async {
      final r = await _rig(
          voice: _meetingSeat(),
          conference: const ConferenceState(
              activeConfId: _confId,
              lobbyStatus: ConferenceLobbyStatus.inCall));
      await r.native.send('osEnd', {'uuid': r.service.liveUuid});
      await r.settle();
      expect(r.conference.leaves, 1);
      expect(r.voice.leaves, 0);
      expect(r.conference.ends, 0);
    });

    test('a meeting host steps out and the meeting runs on', () async {
      final r = await _rig(
          voice: _meetingSeat(),
          conference: const ConferenceState(
              activeConfId: _confId,
              isHost: true,
              lobbyStatus: ConferenceLobbyStatus.inCall));
      await r.native.send('osEnd', {'uuid': r.service.liveUuid});
      await r.settle();
      expect(r.conference.ends, 0, reason: 'never "end for everyone"');
      expect(r.conference.leaves, 0);
      expect(r.voice.leaves, 1);
      expect(r.c.read(conferenceProvider).activeConfId, _confId);
      expect(r.c.read(conferenceProvider).lobbyStatus,
          ConferenceLobbyStatus.steppedOut);
    });
  });

  group('speaker', () {
    setUp(() => debugOsCallSpeakerAction = true);
    tearDown(() => debugOsCallSpeakerAction = null);

    test('begin carries the route; a route change reaches the notification',
        () async {
      final r = await _rig(
          voice: _room(speaker: true), route: AudioRouteKind.speaker);
      expect(r.native.lastOf('begin')['speaker'], isTrue);
      r.native.clear();
      r.routes.set(AudioRouteKind.earpiece);
      await r.settle();
      expect(r.native.methods, ['setSpeaker']);
      expect(r.native.lastOf('setSpeaker')['speaker'], isFalse);
    });

    test('a headset never shows as the loudspeaker', () async {
      final r = await _rig(
          voice: _room(speaker: true), route: AudioRouteKind.bluetooth);
      expect(r.native.lastOf('begin')['speaker'], isFalse);
      r.routes.set(AudioRouteKind.speaker);
      await r.settle();
      expect(r.native.lastOf('setSpeaker')['speaker'], isTrue);
      r.routes.set(AudioRouteKind.wired);
      await r.settle();
      expect(r.native.lastOf('setSpeaker')['speaker'], isFalse);
    });

    test("the notification's Speaker runs the app's own path", () async {
      final r = await _rig(
          call: _outgoing('c1').copyWith(status: CallStatus.active),
          route: AudioRouteKind.earpiece);
      final uuid = r.service.liveUuid;
      r.native.clear();
      await r.native.send('osSpeaker', {'uuid': uuid, 'speaker': true});
      await r.settle();
      expect(r.call.speakers, 1);
      expect(r.call.state.isSpeakerOn, isTrue);
      expect(r.routes.state.activeKind, AudioRouteKind.speaker);
      expect(r.native.lastOf('setSpeaker')['speaker'], isTrue);

      await r.native.send('osSpeaker', {'uuid': uuid, 'speaker': false});
      await r.settle();
      expect(r.call.speakers, 2);
      expect(r.routes.state.activeKind, AudioRouteKind.earpiece);
      expect(r.native.lastOf('setSpeaker')['speaker'], isFalse);
    });

    // Hands-free stale against the route (a headset left): the press sets
    // what the notification asked, never flips a flag the other way.
    test('a press sets the route the notification asked for', () async {
      final r = await _rig(
          call: _outgoing('c1')
              .copyWith(status: CallStatus.active, isSpeakerOn: true),
          route: AudioRouteKind.earpiece);
      await r.native
          .send('osSpeaker', {'uuid': r.service.liveUuid, 'speaker': true});
      await r.settle();
      expect(r.routes.state.activeKind, AudioRouteKind.speaker);
      expect(r.native.lastOf('setSpeaker')['speaker'], isTrue);
    });

    test('a room switches the room speaker', () async {
      final r = await _rig(voice: _room(), route: AudioRouteKind.earpiece);
      await r.native
          .send('osSpeaker', {'uuid': r.service.liveUuid, 'speaker': true});
      await r.settle();
      expect(r.voice.speakers, 1);
      expect(r.voice.state.isSpeakerOn, isTrue);
      expect(r.native.lastOf('setSpeaker')['speaker'], isTrue);
    });

    // The iron rule: a connected headset keeps the audio. The press changes
    // nothing, so the icon stays off; no sheet opens from a notification.
    for (final headset in [AudioRouteKind.wired, AudioRouteKind.bluetooth]) {
      for (final handsFree in [false, true]) {
        test('a press with ${headset.name} active leaves route and icon '
            '(hands-free $handsFree)', () async {
          final r = await _rig(
              call: _outgoing('c1').copyWith(
                  status: CallStatus.active, isSpeakerOn: handsFree),
              route: headset);
          final uuid = r.service.liveUuid;
          expect(r.native.lastOf('begin')['speaker'], isFalse);
          r.native.clear();
          await r.native.send('osSpeaker', {'uuid': uuid, 'speaker': true});
          await r.settle();
          expect(r.call.speakers, 0);
          expect(r.call.state.isSpeakerOn, handsFree);
          expect(r.routes.state.activeKind, headset);
          expect(r.native.of('setSpeaker'), isEmpty);
        });
      }
    }

    test('our own echo, a stranger uuid and a held call change nothing',
        () async {
      final r = await _rig(
          voice: _room(speaker: true), route: AudioRouteKind.speaker);
      final uuid = r.service.liveUuid;
      await r.native.send('osSpeaker', {'uuid': uuid, 'speaker': true});
      await r.native.send('osSpeaker', {'uuid': 'stranger', 'speaker': false});
      await r.native.send('osHold', {'uuid': uuid, 'held': true});
      await r.native.send('osSpeaker', {'uuid': uuid, 'speaker': false});
      await r.settle();
      expect(r.voice.speakers, 0);
      expect(r.routes.state.activeKind, AudioRouteKind.speaker);
    });

    test('iOS (CallKit) is never sent a speaker', () async {
      debugOsCallSpeakerAction = false;
      final r = await _rig(
          voice: _room(speaker: true), route: AudioRouteKind.speaker);
      r.voice.set(_room());
      await r.settle();
      expect(r.native.lastOf('begin').containsKey('speaker'), isFalse);
      expect(r.native.of('setSpeaker'), isEmpty);
    });
  });

  group('hold', () {
    test('held deafens; the app cannot undo it; the OS resume restores it',
        () async {
      final r = await _rig(voice: _room());
      final uuid = r.service.liveUuid;
      await r.native.send('osHold', {'uuid': uuid, 'held': true});
      await r.settle();
      expect(r.voice.state.isDeafened, isTrue);
      expect(r.voice.state.isMuted, isTrue);
      expect(r.service.held, isTrue);

      r.native.clear();
      var acted = false;
      unlessOsHeld(r.c.read, () => acted = true)!();
      await r.settle();
      expect(acted, isFalse, reason: 'the app must not resume a held call');
      expect(r.native.methods.contains('requestUnhold'), isTrue);
      expect(r.voice.deafens, 1);

      await r.native.send('osHold', {'uuid': uuid, 'held': false});
      await r.settle();
      expect(r.voice.state.isDeafened, isFalse);
      expect(r.voice.state.isMuted, isFalse);
      expect(r.service.held, isFalse);
      var after = false;
      unlessOsHeld(r.c.read, () => after = true)!();
      expect(after, isTrue);
    });

    test('a resume gives back exactly what was there: muted stays muted',
        () async {
      final r = await _rig(voice: _room(muted: true));
      final uuid = r.service.liveUuid;
      await r.native.send('osHold', {'uuid': uuid, 'held': true});
      await r.native.send('osHold', {'uuid': uuid, 'held': false});
      await r.settle();
      expect(r.voice.state.isDeafened, isFalse);
      expect(r.voice.state.isMuted, isTrue);
    });

    test('a DM held unmuted comes back unmuted, through the real rule',
        () async {
      final r = await _rig(
          call: _outgoing('c1').copyWith(status: CallStatus.active));
      final uuid = r.service.liveUuid;
      await r.native.send('osHold', {'uuid': uuid, 'held': true});
      await r.settle();
      expect((r.call.state.isMuted, r.call.state.isDeafened), (true, true));
      await r.native.send('osHold', {'uuid': uuid, 'held': false});
      await r.settle();
      expect((r.call.state.isMuted, r.call.state.isDeafened), (false, false));
    });

    // An Unmute pressed on the notification during the carrier call is the
    // app's Unmute: it asks the OS to resume and changes nothing itself (the
    // model would undeafen us into the carrier call).
    test('an OS unmute while held asks to resume and changes nothing',
        () async {
      final r = await _rig(voice: _room());
      final uuid = r.service.liveUuid;
      await r.native.send('osHold', {'uuid': uuid, 'held': true});
      await r.settle();
      r.native.clear();
      await r.native.send('osMute', {'uuid': uuid, 'muted': false});
      await r.settle();
      expect(r.voice.mutes, 0);
      expect((r.voice.state.isMuted, r.voice.state.isDeafened), (true, true));
      expect(r.native.methods, contains('requestUnhold'));
      expect(r.native.lastOf('setMuted')['muted'], isTrue,
          reason: 'the OS hears the truth');
    });

    test('an unhold that was never a hold changes nothing', () async {
      final r = await _rig(voice: _room());
      await r.native
          .send('osHold', {'uuid': r.service.liveUuid, 'held': false});
      await r.settle();
      expect(r.voice.deafens + r.voice.mutes, 0);
    });

    test('nothing to guard when no call is held', () async {
      final r = await _rig();
      expect(osCallHoldIntercept(r.c.read), isFalse);
      expect(unlessOsHeld(r.c.read, null), isNull);
    });
  });

  group('fallback and reset', () {
    test('osFailed: still ended, never re-begun on a reset; the next session '
        'tries the OS again', () async {
      final r = await _rig(voice: _room());
      final uuid = r.service.liveUuid;
      await r.native.send('osFailed', {'uuid': uuid, 'why': 'timeout'});
      await r.native.send('osReset');
      await r.settle();
      expect(r.native.of('begin').length, 1);
      r.voice.set(_room(muted: true));
      await r.settle();
      expect(r.native.lastOf('setMuted')['uuid'], uuid,
          reason: 'an unmirrored key still hears its state (Android fallback)');
      r.voice.set(const VoiceChannelState());
      await r.settle();
      expect(r.native.lastOf('end')['uuid'], uuid);
      r.call.set(_placed('c2'));
      await r.settle();
      expect(r.native.of('begin').length, 2);
      expect(r.native.lastOf('begin')['live'], [r.service.liveUuid]);
    });

    test('a begin native answers ok:false is unmirrored like osFailed',
        () async {
      final r = await _rig();
      r.native.onBegin = (_) => {'ok': false};
      r.voice.set(_room());
      await r.settle();
      await r.native.send('osReset');
      await r.settle();
      expect(r.native.of('begin').length, 1);
    });

    test('a reset begins the live session again under a new uuid and ends '
        'nothing', () async {
      final r = await _rig(voice: _room(muted: true));
      final old = r.service.liveUuid;
      r.native.clear();
      await r.native.send('osReset');
      await r.settle();
      expect(r.native.methods, ['begin', 'connected', 'setMuted']);
      final begin = r.native.lastOf('begin');
      expect(begin['uuid'], isNot(old));
      expect(begin['title'], 'Lounge · Den');
      expect(begin['live'], [begin['uuid']]);
      expect(r.voice.leaves, 0);
    });

    test('a reset while held gives the audio back first', () async {
      final r = await _rig(voice: _room());
      await r.native
          .send('osHold', {'uuid': r.service.liveUuid, 'held': true});
      await r.native.send('osReset');
      await r.settle();
      expect(r.voice.state.isDeafened, isFalse);
      expect(r.service.held, isFalse);
    });

    test('a lost end is corrected by the next begin\'s live set', () async {
      final r = await _rig(voice: _room());
      final first = r.service.liveUuid;
      r.voice.set(const VoiceChannelState());
      r.call.set(_placed('c9'));
      await r.settle();
      final live = r.native.lastOf('begin')['live'] as List;
      expect(live, isNot(contains(first)));
    });

    test('the debug fallback switch reaches native before the first begin',
        () async {
      OsCallService.debugForceFallback = true;
      addTearDown(() => OsCallService.debugForceFallback = null);
      final r = await _rig(voice: _room());
      expect(r.native.calls.first.$1, 'available');
      expect(r.native.calls.first.$2, {'forceFallback': true});
      expect(r.native.calls.where((c) => c.$1 == 'begin'), hasLength(1));
    });

    test('without the switch native is never asked to fall back', () async {
      final r = await _rig(voice: _room());
      expect(r.native.of('available').single, isNot(contains('forceFallback')));
    });
  });

  // Android keeps its call service (never an OS call) up while a call we place
  // rings, so the mic works when the answer finds the app in the background.
  group('Android ring-out', () {
    setUp(() => debugOsCallRingOutService = true);
    tearDown(() => debugOsCallRingOutService = null);

    test('a call ringing out holds the service and begins no OS call',
        () async {
      final r = await _rig();
      r.call.set(_outgoing('c1'));
      await r.settle();
      expect(r.native.methods, ['ringOut']);
      expect(r.native.lastOf('ringOut'), {'on': true, 'title': 'Ada'});
      expect(r.service.probe['osRingOut'], isTrue);
    });

    test('an answer begins the call before the ring lets the service go',
        () async {
      final r = await _rig(call: _outgoing('c1'));
      r.native.clear();
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.methods, ['begin', 'ringOut']);
      expect(r.native.lastOf('ringOut'), {'on': false});
      expect(r.service.probe['osRingOut'], isFalse);
    });

    test('a ring that ends unanswered lets the service go', () async {
      final r = await _rig(call: _outgoing('c1'));
      r.native.clear();
      r.call.set(const CallState());
      await r.settle();
      expect(r.native.methods, ['ringOut']);
      expect(r.native.lastOf('ringOut'), {'on': false});
    });

    test('an incoming ring and a ring from inside a room send nothing',
        () async {
      final r = await _rig();
      r.call.set(_incoming('c1'));
      await r.settle();
      expect(r.native.methods, isEmpty);
      final inRoom = await _rig(voice: _room());
      inRoom.native.clear();
      inRoom.call.set(_outgoing('c2'));
      await inRoom.settle();
      expect(inRoom.native.methods, isNot(contains('ringOut')));
    });

    test('hang up on the ring-out notification cancels only a ringing call',
        () async {
      final r = await _rig(call: _outgoing('c1'));
      await r.native.send('osRingOutEnd');
      await r.settle();
      expect(r.call.ends, 1);
      r.call.set(_placed('c2'));
      await r.settle();
      await r.native.send('osRingOutEnd');
      await r.settle();
      expect(r.call.ends, 1, reason: 'an answered call is not cancelled');
    });

    test('a launch password hides the name on the ring-out too', () async {
      final r = await _rig(protection: _withPassword);
      r.call.set(_outgoing('c1'));
      await r.settle();
      expect(r.native.lastOf('ringOut')['title'], kHiddenNotificationTitle);
    });

    test('iPhones never hear of a ring-out', () async {
      debugOsCallRingOutService = false;
      final r = await _rig();
      r.call.set(_outgoing('c1'));
      await r.settle();
      expect(r.native.methods, isEmpty);
      expect(r.service.probe.containsKey('osRingOut'), isFalse);
    });
  });

  group('title', () {
    test('a launch password hides the name from the start', () async {
      final r = await _rig(protection: _withPassword);
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.lastOf('begin')['title'], kHiddenNotificationTitle);
    });

    test('a protection state not known yet hides the name', () async {
      final native = _Native();
      final c = ProviderContainer(overrides: [
        osCallChannelProvider.overrideWithValue(native),
        callProvider.overrideWith(() => _Call(_placed('c1'))),
        voiceChannelProvider.overrideWith(() => _Voice(const VoiceChannelState())),
        conferenceProvider.overrideWith(() => _Conference(const ConferenceState())),
        profileProvider.overrideWith(_Profiles.new),
        identityProtectionProvider
            .overrideWith((ref) => Future<identity_api.ProtectionStatus>.delayed(
                const Duration(days: 1), () => _noPassword)),
        startCallsOnSpeakerProvider.overrideWith(_Speaker.new),
      ]);
      addTearDown(c.dispose);
      c.read(osCallServiceProvider);
      await pumpEventQueue();
      await c.read(osCallServiceProvider)!.settled;
      expect(native.lastOf('begin')['title'], kHiddenNotificationTitle);
    });

    test('App Lock blanks the name one way; nothing re-reveals it', () async {
      final r = await _rig(voice: _room());
      r.native.clear();
      r.lock.set(true);
      await r.settle();
      expect(r.native.methods, ['update']);
      expect(r.native.lastOf('update')['title'], kHiddenNotificationTitle);
      r.lock.set(false);
      r.voice.set(_room().copyWith(peerCameraOn: {'p': true}));
      await r.settle();
      expect(r.native.lastOf('update')['title'], kHiddenNotificationTitle);
    });

    test('a profile change mid-call renames nothing', () async {
      final r = await _rig(call: _placed('c1'));
      r.native.clear();
      r.profiles.rename('ada', 'Someone else');
      await r.settle();
      expect(r.native.methods, isEmpty);
    });

    test('a name not known yet is never the id', () async {
      final r = await _rig();
      r.call.set(_placed('c1').copyWith(peerId: 'stranger-id'));
      await r.settle();
      expect(r.native.lastOf('begin')['title'], kHiddenNotificationTitle);
    });

    test('an 18+ server this phone hides is never named', () async {
      final r = await _rig(ageHidden: {'s1'});
      r.voice.set(_room());
      await r.settle();
      expect(r.native.lastOf('begin')['title'], kHiddenNotificationTitle);
    });

    test('a meeting guest sees whose meeting it is; the host its name',
        () async {
      final r = await _rig(
          voice: _meetingSeat(),
          conference: const ConferenceState(
              activeConfId: _confId,
              hostName: 'Ada',
              lobbyStatus: ConferenceLobbyStatus.inCall));
      expect(r.native.lastOf('begin')['title'], 'Meeting with Ada');
    });

    test('video changes update the OS with the title fixed at begin',
        () async {
      final r = await _rig(voice: _room());
      r.native.clear();
      r.voice.set(_room().copyWith(isCameraOn: true));
      await r.settle();
      expect(r.native.methods, ['update']);
      expect(r.native.lastOf('update'),
          containsPair('title', 'Lounge · Den'));
      expect(r.native.lastOf('update'), containsPair('video', true));
    });
  });

  group('Android call notification face', () {
    setUp(() {
      debugOsCallAvatars = true;
      debugOsCallRingOutService = true;
    });
    tearDown(() {
      debugOsCallAvatars = null;
      debugOsCallRingOutService = null;
      OsCallService.avatarTimeout = const Duration(seconds: 1);
    });

    Map<String, Object?> face(OsCallAvatar a) =>
        {'avatar': a.rgba, 'avatarSide': a.side};

    /// Every message native was sent that carried a face.
    List<(String, Map<String, Object?>)> faced(_Native n) =>
        [for (final c in n.calls) if (c.$2.containsKey('avatar')) c];

    test('an answered DM call shows the friend\'s face beside the name',
        () async {
      final asked = <String>[];
      final r = await _rig(faces: (m) async {
        asked.add(m);
        return _adaFace;
      });
      r.call.set(_placed('c1'));
      await r.settle();
      final begin = r.native.lastOf('begin');
      expect(begin['title'], 'Ada');
      expect(begin, isNot(contains('avatar')), reason: 'the face follows');
      final update = r.native.lastOf('update');
      expect(update['uuid'], begin['uuid']);
      expect(update['title'], 'Ada');
      expect(update, containsPair('avatar', _adaFace.rgba));
      expect(update, containsPair('avatarSide', 2));
      expect(asked, ['ada'], reason: 'the face is the MASTER\'s');
    });

    test('an answered call begins before its face loads', () async {
      final r = await _rig(faces: (_) => Completer<OsCallAvatar?>().future);
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.lastOf('begin')['title'], 'Ada');
    });

    test('the ring-out shows the face too, after it starts', () async {
      final r = await _rig();
      r.call.set(_outgoing('c1'));
      await r.settle();
      expect(r.native.of('ringOut'), [
        {'on': true, 'title': 'Ada'},
        {'on': true, 'title': 'Ada', ...face(_adaFace)},
      ]);
    });

    test('the ring-out starts before its face loads', () async {
      final r = await _rig(faces: (_) => Completer<OsCallAvatar?>().future);
      r.call.set(_outgoing('c1'));
      await r.settle();
      expect(r.native.of('ringOut'), [
        {'on': true, 'title': 'Ada'}
      ]);
    });

    test('a launch password hides the face with the name, and loads none',
        () async {
      var asked = 0;
      final r = await _rig(
          protection: _withPassword,
          faces: (_) async {
            asked++;
            return _adaFace;
          });
      r.call.set(_outgoing('c1'));
      await r.settle();
      expect(r.native.lastOf('ringOut'),
          {'on': true, 'title': kHiddenNotificationTitle});
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.lastOf('begin')['title'], kHiddenNotificationTitle);
      expect(faced(r.native), isEmpty);
      expect(asked, 0);
    });

    test('a face that loads after the lock rose never shows', () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(faces: (_) => gate.future);
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.lastOf('begin')['title'], 'Ada');
      r.lock.set(true);
      await r.settle();
      gate.complete(_adaFace);
      await r.settle();
      expect(faced(r.native), isEmpty);
      expect(r.native.lastOf('update')['title'], kHiddenNotificationTitle);
    });

    test('a ring-out face that loads after the lock rose never shows',
        () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(faces: (_) => gate.future);
      r.call.set(_outgoing('c1'));
      await r.settle();
      r.lock.set(true);
      await r.settle();
      gate.complete(_adaFace);
      await r.settle();
      expect(faced(r.native), isEmpty);
      expect(r.native.lastOf('ringOut'),
          {'on': true, 'title': kHiddenNotificationTitle});
    });

    test('a lock that rose and fell while the face loaded: the blanked call '
        'never gets it', () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(faces: (_) => gate.future);
      r.call.set(_placed('c1'));
      await r.settle();
      r.lock.set(true);
      await r.settle();
      r.lock.set(false);
      await r.settle();
      gate.complete(_adaFace);
      await r.settle();
      expect(faced(r.native), isEmpty);
    });

    test('a lock that rose and fell while the ring-out face loaded: the '
        'blanked ring never gets it', () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(faces: (_) => gate.future);
      r.call.set(_outgoing('c1'));
      await r.settle();
      r.lock.set(true);
      await r.settle();
      r.lock.set(false);
      await r.settle();
      gate.complete(_adaFace);
      await r.settle();
      expect(faced(r.native), isEmpty);
      expect(r.native.lastOf('ringOut')['title'], kHiddenNotificationTitle);
    });

    test('a lock that rises while a late face waits behind a slow native call '
        'keeps it off', () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(faces: (_) => gate.future);
      r.call.set(_placed('c1'));
      await r.settle();
      r.native
        ..holdMethod = 'update'
        ..hold = Completer<void>();
      r.call.set(_placed('c1', video: true));
      await pumpEventQueue();
      gate.complete(_adaFace);
      await pumpEventQueue();
      // The lock's reconcile queues behind the face's step.
      r.lock.set(true);
      r.native.hold!.complete();
      await r.settle();
      expect(faced(r.native), isEmpty);
      expect(r.native.lastOf('update')['title'], kHiddenNotificationTitle);
    });

    test('App Lock blanks the face with the name, for good', () async {
      final r = await _rig(call: _placed('c1'));
      expect(r.native.lastOf('update'), contains('avatar'));
      r.native.clear();
      r.lock.set(true);
      await r.settle();
      expect(r.native.methods, ['update']);
      expect(r.native.lastOf('update')['title'], kHiddenNotificationTitle);
      expect(r.native.lastOf('update'), isNot(contains('avatar')));
      r.lock.set(false);
      r.call.set(_placed('c1', video: true));
      await r.settle();
      expect(r.native.lastOf('update'), isNot(contains('avatar')));
      expect(r.native.lastOf('update')['title'], kHiddenNotificationTitle);
    });

    test('App Lock during the ring blanks the ring-out, face and all',
        () async {
      final r = await _rig(call: _outgoing('c1'));
      expect(r.native.lastOf('ringOut'), contains('avatar'));
      r.native.clear();
      r.lock.set(true);
      await r.settle();
      expect(r.native.methods, ['ringOut']);
      expect(r.native.lastOf('ringOut'),
          {'on': true, 'title': kHiddenNotificationTitle});
      r.lock.set(false);
      await r.settle();
      expect(r.native.methods, ['ringOut'], reason: 'never named again');
    });

    test('a video update carries the face again', () async {
      final r = await _rig(call: _placed('c1'));
      r.native.clear();
      r.call.set(_placed('c1', video: true));
      await r.settle();
      expect(r.native.lastOf('update'), containsPair('avatar', _adaFace.rgba));
      expect(r.native.lastOf('update'), containsPair('title', 'Ada'));
    });

    test('a name not known yet shows no face either', () async {
      var asked = 0;
      final r = await _rig(faces: (_) async {
        asked++;
        return _adaFace;
      });
      r.call.set(_placed('c1').copyWith(peerId: 'stranger-id'));
      await r.settle();
      expect(r.native.lastOf('begin')['title'], kHiddenNotificationTitle);
      expect(faced(r.native), isEmpty);
      expect(asked, 0);
    });

    test('no face: the notification stays as it was', () async {
      final r = await _rig(faces: (_) async => null);
      r.call.set(_placed('c1'));
      await r.settle();
      expect(r.native.methods, ['begin']);
      expect(faced(r.native), isEmpty);
    });

    test('a face source that throws or hangs never holds the call up',
        () async {
      OsCallService.avatarTimeout = const Duration(milliseconds: 20);
      final hang = await _rig(faces: (_) => Completer<OsCallAvatar?>().future);
      hang.call.set(_placed('c1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await hang.settle();
      expect(hang.native.methods, ['begin']);
      final boom = await _rig(faces: (_) async => throw StateError('no rust'));
      boom.call.set(_placed('c2'));
      await boom.settle();
      expect(boom.native.lastOf('begin')['title'], 'Ada');
      expect(faced(boom.native), isEmpty);
    });

    test('a call that ends while its face loads never gets it', () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(faces: (_) => gate.future);
      r.call.set(_placed('c1'));
      await r.settle();
      r.call.set(const CallState());
      await r.settle();
      gate.complete(_adaFace);
      await r.settle();
      expect(r.native.methods, ['begin', 'end']);
    });

    test('a DM that turns into a room while its face loads gives the room '
        'no face', () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(faces: (_) => gate.future);
      r.call.set(_placed('c1'));
      await pumpEventQueue();
      r.call.set(const CallState());
      r.voice.set(_room());
      await r.settle();
      gate.complete(_adaFace);
      await r.settle();
      expect(r.native.lastOf('begin')['kind'], 'room');
      expect(faced(r.native), isEmpty);
    });

    test('a room joined while a DM rings in gets no face', () async {
      var asked = 0;
      final r = await _rig(
          call: _incoming('c1'),
          faces: (_) async {
            asked++;
            return _adaFace;
          });
      r.voice.set(_room());
      await r.settle();
      expect(r.native.lastOf('begin')['kind'], 'room');
      expect(faced(r.native), isEmpty);
      expect(asked, 0);
    });

    test('a ring answered while its face loads: the face goes to the call, '
        'never back to the ring', () async {
      final ring = Completer<OsCallAvatar?>();
      var loads = 0;
      final r = await _rig(faces: (_) {
        loads++;
        return loads == 1 ? ring.future : Future.value(_adaFace);
      });
      r.call.set(_outgoing('c1'));
      await r.settle();
      r.call.set(_placed('c1'));
      await r.settle();
      ring.complete(_adaFace);
      await r.settle();
      expect([for (final c in faced(r.native)) c.$1], ['update']);
      expect(r.native.lastOf('ringOut'), {'on': false});
    });

    test('a ring that turns into another friend\'s while the face loads '
        'never shows the first friend\'s face', () async {
      final gate = Completer<OsCallAvatar?>();
      final r = await _rig(
          faces: (m) => m == 'ada' ? gate.future : Future.value(null));
      r.c.read(profileProvider);
      r.profiles.rename('bob', 'Bob');
      r.call.set(_outgoing('c1'));
      await pumpEventQueue();
      r.call.set(const CallState());
      r.call.set(_outgoing('c2').copyWith(peerId: 'bob'));
      gate.complete(_adaFace);
      await r.settle();
      final ring = r.native.lastOf('ringOut');
      expect(ring['title'], 'Bob');
      expect(faced(r.native), isEmpty,
          reason: 'Ada\'s face beside Bob\'s name');
    });

    test('a second ring-out between reconciles is re-titled, as a fresh ring',
        () async {
      final r = await _rig(
          call: _outgoing('c1'),
          faces: (m) async => m == 'ada' ? _adaFace : null);
      r.profiles.rename('bob', 'Bob');
      r.call.set(const CallState());
      r.call.set(_outgoing('c2').copyWith(peerId: 'bob'));
      await r.settle();
      final rings = r.native.of('ringOut');
      final ring = rings.last;
      expect(ring['title'], 'Bob', reason: 'still $ring');
      // Native starts the new ring's title over: told it is fresh, or the old
      // ring was let go first.
      expect(
          ring['fresh'] == true || rings[rings.length - 2]['on'] == false,
          isTrue,
          reason: '$rings');
      expect(ring, isNot(contains('avatar')));
    });

    test('rooms and meetings show no face and load none', () async {
      var asked = 0;
      final r = await _rig(faces: (_) async {
        asked++;
        return _adaFace;
      });
      r.voice.set(_room());
      await r.settle();
      expect(faced(r.native), isEmpty);
      final m = await _rig(
          voice: _meetingSeat(),
          conference: const ConferenceState(
              activeConfId: _confId,
              hostName: 'Ada',
              lobbyStatus: ConferenceLobbyStatus.inCall),
          faces: (_) async {
            asked++;
            return _adaFace;
          });
      expect(faced(m.native), isEmpty);
      expect(asked, 0);
    });

    test('iPhones never get a face', () async {
      debugOsCallAvatars = false;
      debugOsCallRingOutService = false;
      var asked = 0;
      final r = await _rig(faces: (_) async {
        asked++;
        return _adaFace;
      });
      r.call.set(_placed('c1'));
      await r.settle();
      expect(faced(r.native), isEmpty);
      expect(asked, 0);
    });
  });

  // A locked phone draws no frames, and Riverpod refreshes a derived provider
  // only on one: the OS hears of a change with no frame pumped.
  group('a locked phone', () {
    Future<_Rig> mounted(WidgetTester tester,
        {CallState call = const CallState(),
        VoiceChannelState voice = const VoiceChannelState()}) async {
      late _Rig r;
      await tester.runAsync(() async {
        r = await _rig(call: call, voice: voice);
      });
      await tester.pumpWidget(UncontrolledProviderScope(
          container: r.c, child: const SizedBox.shrink()));
      r.native.clear();
      return r;
    }

    Future<void> unmount(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    /// [_Rig.settle] reads through the container, and a read refreshes the
    /// derived providers the way a frame would.
    Future<void> settleUnread(OsCallService service) async {
      for (var i = 0; i < 5; i++) {
        await pumpEventQueue();
        await service.settled;
      }
    }

    testWidgets('a remote hang-up ends the OS call', (tester) async {
      final r = await mounted(tester,
          call: _outgoing('c1').copyWith(status: CallStatus.active));
      final service = r.service;
      await tester.runAsync(() async {
        r.call.cause = CallEndCause.remoteEnd;
        r.call.set(const CallState());
        await settleUnread(service);
      });
      expect(r.native.methods, ['end']);
      expect(r.native.lastOf('end')['reason'], 'remote');
      await unmount(tester);
    });

    testWidgets('leaving a room ends the OS call', (tester) async {
      final r = await mounted(tester, voice: _room());
      final service = r.service;
      await tester.runAsync(() async {
        r.voice.set(const VoiceChannelState());
        await settleUnread(service);
      });
      expect(r.native.methods, ['end']);
      await unmount(tester);
    });

    testWidgets('App Lock blanks the name', (tester) async {
      final r = await mounted(tester, voice: _room());
      final service = r.service;
      await tester.runAsync(() async {
        r.lock.set(true);
        await settleUnread(service);
      });
      expect(r.native.methods, ['update']);
      expect(r.native.lastOf('update')['title'], kHiddenNotificationTitle);
      await unmount(tester);
    });
  });

  group('the in-call mute button', () {
    Future<int> tapMute(WidgetTester tester, {required bool held}) async {
      var presses = 0;
      final service = _HeldService(held);
      await tester.pumpWidget(ProviderScope(
        overrides: [osCallServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: CallMuteButton(muted: true, onPressed: () => presses++),
            ),
          ),
        ),
      ));
      await tester.tap(find.byType(CallMuteButton));
      await tester.pump();
      expect(service.unholdAsks, held ? 1 : 0);
      return presses;
    }

    testWidgets('acts while the OS does not hold the call', (tester) async {
      expect(await tapMute(tester, held: false), 1);
    });

    testWidgets('asks the OS to resume a held call instead of unmuting',
        (tester) async {
      expect(await tapMute(tester, held: true), 0);
    });
  });

  // A carrier call holds ours: the loudspeaker would move the carrier call's
  // audio, so Speaker and the route sheet ask the OS to resume, like Unmute.
  group('the in-call speaker control', () {
    // The round button; its word sits under it, outside the press target.
    final speaker = find.byType(HollowPressable).first;
    late int toggles;
    late List<AudioRoute> picked;

    Future<_HeldService> pump(WidgetTester tester,
        {required bool held, List<AudioRoute> attached = const []}) async {
      toggles = 0;
      picked = [];
      final service = _HeldService(held);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          osCallServiceProvider.overrideWithValue(service),
          audioRouteProvider
              .overrideWith(() => _Routes(AudioRouteKind.earpiece, attached)),
        ],
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => MobileCallControlRow(controls: [
                speakerControl(context, ref,
                    on: false,
                    toggle: () => toggles++,
                    select: (route) async => picked.add(route)),
              ]),
            ),
          ),
        ),
      ));
      return service;
    }

    testWidgets('a tap toggles while nothing holds the call', (tester) async {
      final service = await pump(tester, held: false);
      await tester.tap(speaker);
      await tester.pump();
      expect(toggles, 1);
      expect(service.unholdAsks, 0);
    });

    testWidgets('held: a tap asks to resume and moves nothing',
        (tester) async {
      final service = await pump(tester, held: true);
      await tester.tap(speaker);
      await tester.pumpAndSettle();
      expect(toggles, 0);
      expect(service.unholdAsks, 1);
    });

    testWidgets('held: a long press opens no route sheet', (tester) async {
      final service =
          await pump(tester, held: true, attached: [_earpiece, _buds]);
      await tester.longPress(speaker);
      await tester.pumpAndSettle();
      expect(find.text('Audio device'), findsNothing);
      expect(service.unholdAsks, 1);
    });

    testWidgets('held with a headset: a tap opens no route sheet',
        (tester) async {
      final service =
          await pump(tester, held: true, attached: [_earpiece, _buds]);
      await tester.tap(speaker);
      await tester.pumpAndSettle();
      expect(find.text('Audio device'), findsNothing);
      expect(service.unholdAsks, 1);
    });

    testWidgets('a hold that begins while the sheet is open: a pick moves '
        'nothing', (tester) async {
      final service =
          await pump(tester, held: false, attached: [_earpiece, _buds]);
      await tester.tap(speaker);
      await tester.pumpAndSettle();
      expect(find.text('Audio device'), findsOneWidget);
      service.heldNow = true;
      await tester.tap(find.text('Buds'));
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      expect(service.unholdAsks, 1);
      expect(find.text('Audio device'), findsNothing);
    });

    testWidgets('unheld, a pick reaches the call', (tester) async {
      await pump(tester, held: false, attached: [_earpiece, _buds]);
      await tester.longPress(speaker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Buds'));
      await tester.pumpAndSettle();
      expect(picked, [_buds]);
    });
  });
}

const _earpiece =
    AudioRoute(id: 'earpiece', label: 'Phone', kind: AudioRouteKind.earpiece);
const _buds =
    AudioRoute(id: 'bluetooth', label: 'Buds', kind: AudioRouteKind.bluetooth);

T _noRead<T>(ProviderListenable<T> provider) =>
    throw UnimplementedError('not read in this test');

class _HeldService extends OsCallService {
  bool heldNow;
  int unholdAsks = 0;
  _HeldService(this.heldNow) : super(_noRead, _Native());

  @override
  bool get held => heldNow;

  @override
  void requestUnhold() => unholdAsks++;
}

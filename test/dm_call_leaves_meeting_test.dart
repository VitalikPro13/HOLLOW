/// Starting or answering a DM call leaves the voice room first; a meeting guest
/// leaves the meeting itself, never only its voice room (that strands it), and
/// the host is asked whether the meeting ends for everyone or runs on.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/sibling_call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_actions.dart' show dmCallLeavesNote;
import 'package:hollow/src/ui/shell/conference_actions.dart';

class _Voice extends VoiceChannelNotifier {
  final VoiceChannelState seed;
  int leaves = 0;
  int joins = 0;

  /// Whether a join seats us; false throws, as a refused join does.
  bool seats = true;
  _Voice(this.seed);

  @override
  VoiceChannelState build() => seed;

  @override
  Future<void> leaveChannel() async {
    leaves++;
    state = const VoiceChannelState();
  }

  @override
  Future<void> joinChannel(String serverId, String channelId) async {
    joins++;
    if (!seats) throw StateError('refused');
    state = VoiceChannelState(
        currentServerId: serverId, currentChannelId: channelId);
  }
}

class _Conference extends ConferenceNotifier {
  final ConferenceState seed;
  int leaves = 0;
  int ends = 0;
  _Conference(this.seed);

  @override
  ConferenceState build() => seed;

  @override
  Future<void> leaveMeeting() async => leaves++;

  @override
  Future<void> endMeeting() async => ends++;
}

class _Ringing extends CallNotifier {
  @override
  CallState build() => const CallState(
      status: CallStatus.ringing, direction: CallDirection.incoming);

  void hangUp() => state = const CallState();
}

class _Locked extends AppLockedNotifier {
  @override
  bool build() => true;
}

const _confId = 'c0ffee';

void main() {
  late _Voice voice;
  late _Conference conference;

  late _Ringing call;

  ProviderContainer container(
      {required String? serverId,
      String? activeConfId,
      bool isHost = false,
      bool locked = false,
      ConferenceLobbyStatus lobby = ConferenceLobbyStatus.inCall}) {
    voice = _Voice(VoiceChannelState(
        currentServerId: serverId,
        currentChannelId: serverId == null ? null : 'main',
        currentChannelName: serverId == null ? null : 'main'));
    conference = _Conference(ConferenceState(
        activeConfId: activeConfId, isHost: isHost, lobbyStatus: lobby));
    call = _Ringing();
    final c = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(() => voice),
      conferenceProvider.overrideWith(() => conference),
      callProvider.overrideWith(() => call),
      callElsewhereProvider.overrideWithValue(null),
      if (locked) appLockedProvider.overrideWith(_Locked.new),
    ]);
    addTearDown(c.dispose);
    c.read(callProvider);
    return c;
  }

  test('a meeting guest leaves the meeting before the call', () async {
    final c = container(
        serverId: conferenceServerId(_confId), activeConfId: _confId);
    await leaveVoiceForDmCall(c.read);
    expect(conference.leaves, 1);
    expect(voice.leaves, 0, reason: 'a bare voice leave strands the meeting');
    expect(conference.ends, 0);
  });

  test('the host who steps out leaves only the voice room, the meeting runs on',
      () async {
    final c = container(
        serverId: conferenceServerId(_confId),
        activeConfId: _confId,
        isHost: true);
    await leaveVoiceForDmCall(c.read, hostMeeting: HostMeetingChoice.stepOut);
    expect(voice.leaves, 1);
    expect(conference.leaves + conference.ends, 0);
    expect(c.read(conferenceProvider).lobbyStatus,
        ConferenceLobbyStatus.steppedOut,
        reason: 'never "in the call" with no seat behind it');
    expect(c.read(conferenceProvider).activeConfId, _confId);
  });

  group('back into the meeting', () {
    ProviderContainer steppedOut(
            {ConferenceLobbyStatus lobby = ConferenceLobbyStatus.steppedOut}) =>
        container(
            serverId: null, activeConfId: _confId, isHost: true, lobby: lobby);

    ConferenceLobbyStatus status(ProviderContainer c) =>
        c.read(conferenceProvider).lobbyStatus;

    test('Rejoin seats us in the meeting room again', () async {
      final c = steppedOut();
      call.hangUp();
      await c.read(conferenceProvider.notifier).rejoin();
      expect(voice.joins, 1);
      expect(c.read(voiceChannelProvider).currentServerId,
          conferenceServerId(_confId));
      expect(status(c), ConferenceLobbyStatus.inCall);
    });

    test('a seat that never comes leaves it stepped out, never ended',
        () async {
      final c = steppedOut();
      call.hangUp();
      voice.seats = false;
      await c.read(conferenceProvider.notifier).rejoin();
      expect(voice.joins, 1);
      expect(conference.ends + conference.leaves, 0,
          reason: 'the meeting ran on without us and still does');
      expect(status(c), ConferenceLobbyStatus.steppedOut);
    });

    test('nothing rejoins while the DM call runs', () async {
      final c = steppedOut();
      await c.read(conferenceProvider.notifier).rejoin();
      expect(voice.joins, 0);
      expect(status(c), ConferenceLobbyStatus.steppedOut);
    });

    test('nothing rejoins on its own once the call ends', () async {
      final c = steppedOut();
      call.hangUp();
      await Future<void>.delayed(Duration.zero);
      expect(voice.joins, 0);
      expect(status(c), ConferenceLobbyStatus.steppedOut);
    });

    for (final lobby in [
      ConferenceLobbyStatus.steppedOut,
      ConferenceLobbyStatus.inCall,
    ]) {
      test('starting the meeting again re-seats a host who is ${lobby.name} '
          'with no seat', () async {
        final c = steppedOut(lobby: lobby);
        call.hangUp();
        await c.read(conferenceProvider.notifier).startMeeting(
            const ConferenceRoom(
                confId: _confId,
                linkKey: '',
                name: 'm',
                waitingRoom: false,
                hasAccessCode: false,
                broadcastMode: false,
                createdAt: 0));
        expect(voice.joins, 1);
        expect(status(c), ConferenceLobbyStatus.inCall);
      });
    }

    test('a seated host is not re-seated', () async {
      final c = container(
          serverId: conferenceServerId(_confId),
          activeConfId: _confId,
          isHost: true);
      call.hangUp();
      await c.read(conferenceProvider.notifier).rejoin();
      expect(voice.joins, 0);
      expect(status(c), ConferenceLobbyStatus.inCall);
    });
  });

  group('what the call says it leaves', () {
    test('a meeting is named as the meeting, never its room "main"', () {
      final c = container(
          serverId: conferenceServerId(_confId), activeConfId: _confId);
      expect(dmCallLeavesNote(c.read, answering: true),
          'Answering takes you out of the meeting');
      expect(dmCallLeavesNote(c.read, answering: false),
          'Starting this call takes you out of the meeting.');
    });

    test('a voice channel is named by its channel', () {
      final c = container(serverId: 'server-1');
      expect(dmCallLeavesNote(c.read, answering: true),
          'Answering will leave #main');
      expect(dmCallLeavesNote(c.read, answering: false),
          'Starting this call will disconnect you from #main.');
    });

    test('nothing is said outside a voice room', () {
      final c = container(serverId: null);
      expect(dmCallLeavesNote(c.read, answering: true), isNull);
    });
  });

  test('the host who ends the meeting ends it for everyone', () async {
    final c = container(
        serverId: conferenceServerId(_confId),
        activeConfId: _confId,
        isHost: true);
    await leaveVoiceForDmCall(c.read,
        hostMeeting: HostMeetingChoice.endForEveryone);
    expect(conference.ends, 1);
    expect(voice.leaves + conference.leaves, 0);
  });

  test('a guest leaves the meeting whatever the host choice says', () async {
    final c = container(
        serverId: conferenceServerId(_confId), activeConfId: _confId);
    await leaveVoiceForDmCall(c.read,
        hostMeeting: HostMeetingChoice.endForEveryone);
    expect(conference.leaves, 1);
    expect(conference.ends + voice.leaves, 0, reason: 'only the host ends it');
  });

  group('the host question', () {
    const title = 'End the meeting too?';

    /// Pumps a button that asks, and returns a getter for the answer.
    Future<HostMeetingChoice? Function()> pumpAsk(
        WidgetTester tester, ProviderContainer c,
        {bool answering = false}) async {
      HostMeetingChoice? answer;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => answer = await askMeetingHostBeforeDmCall(
                    context, c.read,
                    answering: answering),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      return () => answer;
    }

    ProviderContainer hosting({bool locked = false}) => container(
        serverId: conferenceServerId(_confId),
        activeConfId: _confId,
        isHost: true,
        locked: locked);

    testWidgets('Cancel answers null and changes nothing', (tester) async {
      final answer = await pumpAsk(tester, hosting());
      expect(find.text(title), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text(title), findsNothing);
      expect(answer(), isNull);
      expect(voice.leaves + conference.leaves + conference.ends, 0);
    });

    testWidgets('End for everyone answers endForEveryone', (tester) async {
      final answer = await pumpAsk(tester, hosting());
      await tester.tap(find.text('End for everyone'));
      await tester.pumpAndSettle();
      expect(answer(), HostMeetingChoice.endForEveryone);
    });

    testWidgets('Keep it running answers stepOut', (tester) async {
      final answer = await pumpAsk(tester, hosting());
      await tester.tap(find.text('Keep it running'));
      await tester.pumpAndSettle();
      expect(answer(), HostMeetingChoice.stepOut);
    });

    testWidgets('a guest is never asked', (tester) async {
      final c = container(
          serverId: conferenceServerId(_confId), activeConfId: _confId);
      final answer = await pumpAsk(tester, c, answering: true);
      expect(find.text(title), findsNothing);
      expect(answer(), HostMeetingChoice.stepOut);
    });

    testWidgets('nothing is asked above the App Lock cover', (tester) async {
      final answer = await pumpAsk(tester, hosting(locked: true),
          answering: true);
      expect(find.text(title), findsNothing);
      expect(answer(), HostMeetingChoice.stepOut,
          reason: 'the meeting runs on, as before the question existed');
    });

    testWidgets('answering, the question leaves once the call stops ringing',
        (tester) async {
      final answer = await pumpAsk(tester, hosting(), answering: true);
      expect(find.text(title), findsOneWidget);
      call.hangUp();
      await tester.pumpAndSettle();
      expect(find.text(title), findsNothing);
      expect(answer(), isNull);
    });
  });

  test('every voice leave in the call provider goes through the helper', () {
    final src = File('lib/src/core/providers/call_provider.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(RegExp(r'\.leaveChannel\(\)').allMatches(src).length, 1,
        reason: 'only leaveVoiceForDmCall may call leaveChannel()');
    expect(src,
        contains('await leaveVoiceForDmCall(ref.read, hostMeeting: hostMeeting);'));
    expect('_leaveVoiceChannelIfActive(hostMeeting)'.allMatches(src).length, 2,
        reason: 'startCall and acceptCall both pass the host choice on');
  });

  test('every way into a DM call asks the host first and stops on Cancel', () {
    for (final (path, call) in [
      ('lib/src/ui/call/call_actions.dart', 'calls.startCall(master,'),
      ('lib/src/ui/dialogs/incoming_call_dialog.dart', 'calls.acceptCall('),
      ('lib/src/ui/mobile/mobile_incoming_call.dart', '.acceptCall('),
    ]) {
      final src = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      final ask = src.indexOf('askMeetingHostBeforeDmCall(');
      final stop = src.indexOf(RegExp(r'if \((hostMeeting|choice) == null'));
      final go = src.indexOf(call);
      expect(ask, isNonNegative, reason: '$path asks');
      expect(stop, greaterThan(ask), reason: '$path stops on Cancel');
      expect(go, greaterThan(stop), reason: '$path calls only after');
      expect(src, contains('hostMeeting: hostMeeting'),
          reason: '$path passes the choice on');
    }
  });

  test('the start confirm says what the call leaves through the one helper', () {
    final src = File('lib/src/ui/call/call_actions.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(src, contains('dmCallLeavesNote(ref.read, answering: false)'));
    expect(src, isNot(contains('disconnect you from #\$')));
  });

  test('a server voice room is left directly', () async {
    final c = container(serverId: 'server-1', activeConfId: _confId);
    await leaveVoiceForDmCall(c.read);
    expect(voice.leaves, 1);
    expect(conference.leaves + conference.ends, 0);
  });
}

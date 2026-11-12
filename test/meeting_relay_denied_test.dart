/// A meeting this relay refused (t14-deny) is left at once, at any stage, so no
/// notice stays to offer Try again. Starting, joining or rejoining it again asks
/// the relay about that meeting's room alone first: a lifted meeting starts, a
/// still refused one starts nothing and says why.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/sibling_call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/conference.dart' as conference_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/chat/hollow_link_card.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/shell/conference_dashboard.dart';

import 'helpers/test_app.dart';

const _confId = '5e78ccb07e4a5a19c856a513fd358674615650e8';
final _sid = conferenceServerId(_confId);

class _Api implements RustLibApi {
  /// Asks about one room, by room.
  final List<String> asks = [];

  /// Asks about every refusal at once: a meeting never sends one.
  int globalRetries = 0;
  int starts = 0;
  int knocks = 0;
  int ends = 0;
  int leaves = 0;
  final List<String> logs = [];
  void Function()? onAsk;

  void reset() {
    asks.clear();
    logs.clear();
    globalRetries = starts = knocks = ends = leaves = 0;
    onAsk = null;
  }

  @override
  Future<List<conference_api.ConferenceInfo>> crateApiConferenceConferenceList() async =>
      const [];

  @override
  Future<void> crateApiConferenceConferenceRequestJoin({
    required String confId,
    required String linkKey,
    required String displayName,
    required String avatarHash,
    String? accessCode,
  }) async =>
      knocks++;

  @override
  Future<void> crateApiNetworkRetryRelayDenials() async => globalRetries++;

  @override
  Future<void> crateApiNetworkRetryRelayDenial({required String room}) async {
    asks.add(room);
    onAsk?.call();
  }

  @override
  Future<void> crateApiConferenceConferenceStart({
    required String confId,
    required String hostDisplayName,
    required String hostAvatarHash,
  }) async =>
      starts++;

  @override
  Future<void> crateApiConferenceConferenceEnd({required String confId}) async =>
      ends++;

  @override
  Future<void> crateApiConferenceConferenceLeave({required String confId}) async =>
      leaves++;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async =>
      logs.add(message);

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

/// Declines a refused room the way the real joinChannel does: quietly.
class _Voice extends VoiceChannelNotifier {
  int seatTries = 0;

  @override
  VoiceChannelState build() => const VoiceChannelState();

  @override
  Future<void> joinChannel(String serverId, String channelId) async {
    seatTries++;
    if (ref.read(serverRelayDeniedProvider(serverId))) return;
    state = VoiceChannelState(
        currentServerId: serverId, currentChannelId: channelId);
  }

  @override
  Future<void> leaveChannel() async => state = const VoiceChannelState();
}

class _Idle extends CallNotifier {
  @override
  CallState build() => const CallState();
}

class _NoRelayOnly extends AlwaysRelayCallsNotifier {
  @override
  bool build() => false;
}

const _room = ConferenceRoom(
    confId: _confId,
    linkKey: '',
    name: 'm',
    waitingRoom: false,
    hasAccessCode: false,
    broadcastMode: false,
    createdAt: 0);

final _linkKey = 'k' * 43;

final _refOf = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  late _Voice voice;

  setUpAll(() => RustLib.initMock(api: api));

  List<Override> overrides({required bool denied}) {
    api.reset();
    voice = _Voice();
    return [
      voiceChannelProvider.overrideWith(() => voice),
      callProvider.overrideWith(_Idle.new),
      callElsewhereProvider.overrideWithValue(null),
      alwaysRelayCallsProvider.overrideWith(_NoRelayOnly.new),
      relayDeniedServersProvider
          .overrideWith((_) => denied ? {_sid} : <String>{}),
    ];
  }

  ProviderContainer container({required bool denied}) {
    final c = ProviderContainer(overrides: overrides(denied: denied));
    addTearDown(c.dispose);
    return c;
  }

  void lift(ProviderContainer c) =>
      c.read(relayDeniedServersProvider.notifier).state = const {};

  /// The relay refuses the meeting without the leave having run: what a
  /// start or rejoin meets if anything ever skips it.
  void markRefused(ProviderContainer c) {
    final d = c.read(relayDeniedServersProvider.notifier);
    d.state = {...d.state, _sid};
  }

  /// What event_provider does on NetworkEvent_ServerUnavailable.
  void refuse(ProviderContainer c) {
    markRefused(c);
    leaveRefusedVoice(c.read(_refOf), _sid);
  }

  Future<void> hostSteppedOut(ProviderContainer c) async {
    final conf = c.read(conferenceProvider.notifier);
    await conf.startMeeting(_room);
    expect(c.read(conferenceProvider).lobbyStatus, ConferenceLobbyStatus.inCall);
    await conf.stepOut(); // the host took a DM call
  }

  test('a meeting the relay still refuses is asked about again, and nothing starts',
      () async {
    final c = container(denied: true);
    await c.read(conferenceProvider.notifier).startMeeting(_room);
    expect(api.asks, [_sid], reason: "the relay is asked about this meeting's room");
    expect(api.globalRetries, 0, reason: 'no other refusal is asked about');
    expect(api.starts, 0, reason: 'no meeting the relay refuses');
    expect(voice.seatTries, 0);
    expect(c.read(conferenceProvider).activeConfId, isNull);
    expect(c.read(conferenceProvider).askingRelayFor, isNull,
        reason: 'the busy state ends with the ask');
  });

  test('a meeting the relay lifted starts once it has been asked again',
      () async {
    final c = container(denied: true);
    api.onAsk = () => Timer(const Duration(milliseconds: 300), () => lift(c));
    await c.read(conferenceProvider.notifier).startMeeting(_room);
    expect(api.asks, [_sid]);
    expect(api.starts, 1);
    expect(voice.seatTries, 1);
  });

  test('a meeting the relay carries starts without asking', () async {
    final c = container(denied: false);
    await c.read(conferenceProvider.notifier).startMeeting(_room);
    expect(api.asks, isEmpty);
    expect(api.starts, 1);
  });

  test('a guest knocks on a meeting the relay still refuses only after asking again',
      () async {
    final c = container(denied: true);
    final notifier = c.read(conferenceProvider.notifier);
    await notifier.requestJoin(_confId, linkKey: _linkKey);
    expect(api.asks, [_sid]);
    expect(api.knocks, 0, reason: 'no knock through a relay that refuses it');
    api.onAsk = () => lift(c);
    await notifier.requestJoin(_confId, linkKey: _linkKey);
    expect(api.asks, [_sid, _sid]);
    expect(api.knocks, 1, reason: 'lifted: the knock goes');
    expect(api.globalRetries, 0);
  });

  test('a second knock while the relay is being asked shares the ask and knocks once',
      () async {
    final c = container(denied: true);
    api.onAsk = () => Timer(const Duration(milliseconds: 300), () => lift(c));
    final notifier = c.read(conferenceProvider.notifier);
    final first = notifier.requestJoin(_confId, linkKey: _linkKey);
    final second = notifier.requestJoin(_confId, linkKey: _linkKey);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.read(conferenceProvider).askingRelayFor, _confId,
        reason: 'the screens show the ask as joining');
    await Future.wait([first, second]);
    expect(api.asks, [_sid], reason: 'one ask');
    expect(api.knocks, 1, reason: 'one knock');
    expect(c.read(conferenceProvider).askingRelayFor, isNull);
  });

  test('a dropped ask starts nothing, whatever the relay answers', () async {
    final c = container(denied: true);
    api.onAsk = () => Timer(const Duration(milliseconds: 300), () => lift(c));
    final notifier = c.read(conferenceProvider.notifier);
    final knock = notifier.requestJoin(_confId, linkKey: _linkKey);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    notifier.dropRelayAsk();
    expect(c.read(conferenceProvider).askingRelayFor, isNull);
    await knock;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(api.knocks, 0);
  });

  test('a stepped-out host whose meeting is refused is not left in a meeting that cannot seat',
      () async {
    final c = container(denied: false);
    await hostSteppedOut(c);
    refuse(c); // the relay refuses the meeting meanwhile
    await Future<void>.delayed(Duration.zero);
    expect(c.read(conferenceProvider).activeConfId, isNull,
        reason: 'a refused meeting is left, seated or not');
    expect(api.ends, 1, reason: 'a host ends it through the meeting path');
  });

  test('a guest still in the waiting room of a refused meeting leaves it',
      () async {
    final c = container(denied: false);
    await c
        .read(conferenceProvider.notifier)
        .requestJoin(_confId, linkKey: _linkKey);
    expect(c.read(conferenceProvider).lobbyStatus, ConferenceLobbyStatus.waiting);
    refuse(c);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(conferenceProvider).activeConfId, isNull);
    expect(api.leaves, 1, reason: 'a guest leaves through the meeting path');
  });

  test('Start meeting on a stepped-out refused meeting asks the relay before any seat',
      () async {
    final c = container(denied: false);
    await hostSteppedOut(c);
    refuse(c);
    api.asks.clear();
    voice.seatTries = 0;
    final conf = c.read(conferenceProvider.notifier);
    final start = conf.startMeeting(_room);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(api.asks, [_sid], reason: 'the relay is asked again first');
    expect(voice.seatTries, 0,
        reason: 'no seat attempt (20 s wait) on a refused meeting');
    await start;
  });

  for (final viaStart in [true, false]) {
    test(
        viaStart
            ? 'Start meeting on a stepped-out meeting the relay refuses asks before it rejoins'
            : 'a rejoin of a meeting the relay refuses asks first and leaves it',
        () async {
      final c = container(denied: false);
      await hostSteppedOut(c);
      markRefused(c);
      voice.seatTries = 0;
      final conf = c.read(conferenceProvider.notifier);
      await (viaStart ? conf.startMeeting(_room) : conf.rejoin());
      expect(api.asks, [_sid]);
      expect(voice.seatTries, 0, reason: 'no seat through a relay that refuses it');
      expect(c.read(conferenceProvider).activeConfId, isNull,
          reason: 'a meeting the relay still refuses is left');
    });
  }

  testWidgets('a meeting still refused says why through the event toast',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(denied: true),
      child: MaterialApp(
        navigatorKey: hollowNavigatorKey,
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ));
    final c = ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
    await tester.runAsync(
        () => c.read(conferenceProvider.notifier).startMeeting(_room));
    await tester.pump();
    expect(api.logs, contains('[HOLLOW-TOAST] relay_denied_meeting $_sid'));
    expect(find.text(kMeetingDeniedText), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  group('while the relay is asked, the screens show joining', () {
    Future<_Asking> pumpAsking(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final asking = _Asking();
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(
            extra: [conferenceProvider.overrideWith(() => asking)]),
        child: MaterialApp(theme: HollowThemeData.dark(), home: home),
      ));
      await tester.pump();
      return asking;
    }

    for (final (where, home) in [
      ('desktop', const Scaffold(body: ConferenceDashboard()) as Widget),
      ('phone', const MobileConferencesRoute()),
    ]) {
      testWidgets('$where: the Conferences page says joining and can drop it',
          (tester) async {
        final asking = await pumpAsking(tester, home);
        expect(find.text('Joining the meeting'), findsOneWidget);
        expect(find.text('No conference rooms yet'), findsNothing);
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        expect(asking.dropped, isTrue);
      });
    }

    testWidgets("the link card's Join shows busy", (tester) async {
      await pumpAsking(
          tester,
          Scaffold(
            body: HollowLinkCard(
              link: HollowLink(
                  type: HollowLinkType.conference,
                  fullUrl: 'hollow://conference/$_confId',
                  id: _confId,
                  key: _linkKey),
            ),
          ));
      expect(
          tester
              .widget<HollowButton>(find.widgetWithText(HollowButton, 'Join'))
              .loading,
          isTrue);
    });
  });
}

/// A start or knock whose relay ask is running.
class _Asking extends ConferenceNotifier {
  bool dropped = false;

  @override
  ConferenceState build() =>
      const ConferenceState(roomsLoaded: true, askingRelayFor: _confId);

  @override
  Future<void> loadRooms() async {}

  @override
  void dropRelayAsk() {
    dropped = true;
    state = state.copyWith(clearAsking: true);
  }
}

/// A host who stepped out of their meeting for a DM call sees Rejoin, on the
/// desktop dashboard and the phone, never the "Joining the meeting" spinner,
/// and nothing seats them until they press it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/shell/conference_dashboard.dart';

import '../helpers/test_app.dart';

const _confId = 'c0ffee';

class _Meeting extends ConferenceNotifier {
  final ConferenceState seed;
  int rejoins = 0;
  _Meeting(this.seed);

  @override
  ConferenceState build() => seed;

  @override
  Future<void> loadRooms() async {}

  @override
  Future<void> rejoin() async => rejoins++;
}

class _Voice extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState();
}

void main() {
  late _Meeting meeting;

  Future<void> pump(WidgetTester tester, Widget screen,
      {required Size size,
      bool isHost = true,
      ConferenceLobbyStatus lobby = ConferenceLobbyStatus.steppedOut}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    meeting = _Meeting(ConferenceState(
      roomsLoaded: true,
      rooms: const [
        ConferenceRoom(
            confId: _confId,
            linkKey: '',
            name: 'Weekly sync',
            waitingRoom: false,
            hasAccessCode: false,
            broadcastMode: false,
            createdAt: 0),
      ],
      activeConfId: _confId,
      isHost: isHost,
      lobbyStatus: lobby,
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        connectionStatusProvider.overrideWith(TestRelayStatus.new),
        conferenceProvider.overrideWith(() => meeting),
        voiceChannelProvider.overrideWith(_Voice.new),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: screen),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  for (final lobby in [
    ConferenceLobbyStatus.steppedOut,
    ConferenceLobbyStatus.inCall,
  ]) {
    testWidgets('desktop: a host out of the call (${lobby.name}) gets Rejoin',
        (tester) async {
      await pump(tester, const ConferenceDashboard(),
          size: const Size(1280, 800), lobby: lobby);
      expect(find.text('You stepped out'), findsOneWidget);
      expect(find.text('Joining the meeting'), findsNothing);
      expect(find.byType(HollowSpinner), findsNothing);
      expect(find.text('End meeting'), findsOneWidget);
      expect(meeting.rejoins, 0, reason: 'nothing rejoins by itself');
      await tester.tap(find.text('Rejoin'));
      await tester.pump();
      expect(meeting.rejoins, 1);
    });
  }

  testWidgets('desktop: a guest out of the call can rejoin or leave',
      (tester) async {
    await pump(tester, const ConferenceDashboard(),
        size: const Size(1280, 800),
        isHost: false,
        lobby: ConferenceLobbyStatus.inCall);
    expect(find.text('Rejoin'), findsOneWidget);
    expect(find.text('Leave'), findsOneWidget);
  });

  testWidgets('phone: a host who stepped out gets Rejoin, not Open call',
      (tester) async {
    await pump(tester, const MobileConferencesRoute(),
        size: const Size(390, 844));
    expect(find.text('Rejoin'), findsOneWidget);
    expect(find.text('Open call'), findsNothing);
    expect(find.text('End meeting'), findsOneWidget);
    expect(meeting.rejoins, 0, reason: 'nothing rejoins by itself');
    await tester.tap(find.text('Rejoin'));
    await tester.pump();
    expect(meeting.rejoins, 1);
  });
}

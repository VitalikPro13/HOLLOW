/// The tray's Leave in a meeting goes through the meeting (a joiner leaves it,
/// the host ends it after the same question the window asks), never the bare
/// voice leave, which strands the meeting.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/tray_service.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:tray_manager/tray_manager.dart';

import 'helpers/test_app.dart';

class _Voice extends VoiceChannelNotifier {
  final VoiceChannelState seed;
  int leaves = 0;
  _Voice(this.seed);

  @override
  VoiceChannelState build() => seed;

  @override
  Future<void> leaveChannel() async => leaves++;
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

class _Locked extends AppLockedNotifier {
  @override
  bool build() => true;
}

const _confId = 'c0ffee';

void main() {
  late _Voice voice;
  late _Conference conference;
  final windowCalls = <String>[];

  setUp(() {
    windowCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'),
            (call) async {
      windowCalls.add(call.method);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required String serverId,
    String? activeConfId,
    bool isHost = false,
    bool locked = false,
  }) async {
    voice = _Voice(VoiceChannelState(
        currentServerId: serverId, currentChannelId: 'main'));
    conference = _Conference(
        ConferenceState(activeConfId: activeConfId, isHost: isHost));
    final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        voiceChannelProvider.overrideWith(() => voice),
        conferenceProvider.overrideWith(() => conference),
        if (locked) appLockedProvider.overrideWith(_Locked.new),
      ]),
    );
    addTearDown(container.dispose);
    await TrayService.instance.init(container, quitApp: () async {});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: hollowNavigatorKey,
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    ));
    return container;
  }

  Future<void> clickLeave(WidgetTester tester) async {
    TrayService.instance.onTrayMenuItemClick(MenuItem(key: 'leave'));
    await tester.pumpAndSettle();
  }

  testWidgets('a joiner leaves the meeting, not just its voice room',
      (tester) async {
    await pump(tester,
        serverId: conferenceServerId(_confId), activeConfId: _confId);
    await clickLeave(tester);
    expect(conference.leaves, 1);
    expect(conference.ends, 0);
    expect(voice.leaves, 0, reason: 'a bare voice leave strands the meeting');
  });

  testWidgets('the host is asked first, then the meeting ends',
      (tester) async {
    await pump(tester,
        serverId: conferenceServerId(_confId),
        activeConfId: _confId,
        isHost: true);
    await clickLeave(tester);
    expect(windowCalls, contains('show'),
        reason: 'the question is asked in view');
    expect(find.text('End the meeting?'), findsOneWidget);
    expect(conference.ends, 0, reason: 'nothing ends before the answer');
    expect(voice.leaves, 0);

    await tester.tap(find.text('End meeting'));
    await tester.pumpAndSettle();
    expect(conference.ends, 1);
    expect(conference.leaves, 0);
    expect(voice.leaves, 0);
  });

  testWidgets('a locked app shows no question above its cover and ends nothing',
      (tester) async {
    await pump(tester,
        serverId: conferenceServerId(_confId),
        activeConfId: _confId,
        isHost: true,
        locked: true);
    await clickLeave(tester);
    expect(find.text('End the meeting?'), findsNothing);
    expect(conference.ends, 0);
    expect(voice.leaves, 0);
  });

  String? leaveLabel() => TrayService.instance
      .debugMenu()
      .items
      ?.where((i) => i.key == 'leave')
      .firstOrNull
      ?.label;

  testWidgets('the tray names what Leave does', (tester) async {
    await pump(tester,
        serverId: conferenceServerId(_confId), activeConfId: _confId);
    expect(leaveLabel(), 'Leave Meeting');
    await pump(tester,
        serverId: conferenceServerId(_confId),
        activeConfId: _confId,
        isHost: true);
    expect(leaveLabel(), 'End Meeting…');
    await pump(tester, serverId: 'server-1');
    expect(leaveLabel(), 'Leave Voice Channel');
  });

  testWidgets('a server voice room is still left directly', (tester) async {
    await pump(tester, serverId: 'server-1');
    await clickLeave(tester);
    expect(voice.leaves, 1);
    expect(conference.leaves + conference.ends, 0);
  });

  testWidgets('a voice room beside a meeting held elsewhere is left directly',
      (tester) async {
    await pump(tester, serverId: 'server-1', activeConfId: _confId);
    await clickLeave(tester);
    expect(voice.leaves, 1);
    expect(conference.leaves + conference.ends, 0);
  });
}

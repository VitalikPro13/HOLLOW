// t14-deny: a server this relay refuses opens read-only (desktop and phone), a
// pending join says why, and a refused account or network gets the shell dialog.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/relay_denied_notice.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/dialogs/relay_denied_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_connection_indicator.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Every FFI call stays pending, so the pane sits in its loading state.
class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

Future<void> _pumpChat(WidgetTester tester,
    {required bool phone, required bool denied}) async {
  tester.view.physicalSize = phone ? const Size(400, 800) : const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final channel = testChannels[kChannelId1]!;
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: hollowTestOverrides(extra: [
      selectedServerProvider.overrideWith((_) => kServerId1),
      selectedChannelProvider.overrideWith((_) => kChannelId1),
      relayDeniedServersProvider
          .overrideWith((_) => denied ? {kServerId1.toLowerCase()} : <String>{}),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: phone
          ? MobileChatRoute(
              serverId: kServerId1,
              channelId: channel.channelId,
              channelName: channel.name,
            )
          : Scaffold(
              body: ChannelChatPane(
                serverId: kServerId1,
                channelId: channel.channelId,
                channelName: channel.name,
              ),
            ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder get _composer => find.byType(EditableText);

void main() {
  setUpAll(() {
    RustLib.initMock(api: _PendingApi());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  for (final phone in [false, true]) {
    final where = phone ? 'phone' : 'desktop';
    testWidgets('$where: a refused server shows the notice instead of the composer',
        (tester) async {
      await _pumpChat(tester, phone: phone, denied: true);
      expect(find.text(kServerDeniedText), findsOneWidget);
      expect(find.text(kDeniedKeepsText), findsOneWidget);
      expect(find.text('Leave server'), findsOneWidget);
      expect(find.text('Clear messages'), findsOneWidget);
      expect(find.text('Terms of use'), findsOneWidget);
      expect(_composer, findsNothing, reason: 'nothing to type into');
    });

    testWidgets('$where: a server the relay carries keeps its composer',
        (tester) async {
      await _pumpChat(tester, phone: phone, denied: false);
      expect(find.text(kServerDeniedText), findsNothing);
      expect(_composer, findsWidgets);
    });
  }

  testWidgets('a refused meeting says meeting and offers no leave or clear',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: RelayDeniedNotice(serverId: 'conf:abc', meeting: true),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text(kMeetingDeniedText), findsOneWidget);
    expect(find.text('Leave server'), findsNothing);
    expect(find.text('Terms of use'), findsOneWidget);
  });

  for (final (kind, words) in [
    ('account_denied', 'This relay does not accept this account'),
    ('network_denied', 'This relay does not accept connections from your network'),
  ]) {
    testWidgets('$kind: the shell dialog says which and offers both ways out',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(body: RelayDeniedDialog(kind: kind)),
        ),
      ));
      await tester.pump();
      expect(find.text(kRelayLoginDeniedTitle), findsOneWidget);
      expect(find.textContaining(words), findsOneWidget);
      expect(find.textContaining(kLoginDeniedStopsText), findsOneWidget);
      expect(find.text('Relay settings'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  }

  testWidgets('a refused login waits behind the app lock and shows once it lifts',
      (tester) async {
    late ProviderContainer c;
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: _DenialHost()),
      ),
    ));
    c = ProviderScope.containerOf(tester.element(find.byType(_DenialHost)));
    c.read(appLockedProvider.notifier).setLocked(true);
    c.read(relayLoginDenialProvider.notifier).state = 'account_denied';
    await tester.pumpAndSettle();
    expect(find.text(kRelayLoginDeniedTitle), findsNothing,
        reason: 'nothing routes above the lock cover');
    c.read(appLockedProvider.notifier).setLocked(false);
    await tester.pumpAndSettle();
    expect(find.text(kRelayLoginDeniedTitle), findsOneWidget);
  });

  testWidgets('the refused-login status names the refusal', (tester) async {
    expect(OverallConnection.refused.label, kRelayRefusedStatus);
    expect(OverallConnection.refused.isDown, isTrue);
    expect(OverallConnection.refused.isOnline, isFalse);
  });

  testWidgets('the notice asks the relay again', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: RelayDeniedNotice(serverId: 'abc')),
      ),
    ));
    await tester.pump();
    final tryAgain = find.widgetWithText(HollowButton, 'Try again');
    expect(tryAgain, findsOneWidget);
    await tester.tap(tryAgain);
    await tester.pump();
    expect(tester.widget<HollowButton>(tryAgain).loading, isTrue,
        reason: 'the ask shows busy');
    await tester.pump(const Duration(seconds: 5));
    expect(tester.widget<HollowButton>(tryAgain).loading, isFalse);
  });

  for (final official in [true, false]) {
    testWidgets(
        official
            ? 'the official relay opens the Terms with no warning'
            : 'a self-hosted relay opens the Terms under a warning naming it',
        (tester) async {
      const other = 'relay.example.org';
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: ProviderScope(
          overrides: [
            relayDomainProvider.overrideWith(
                () => _Domain(official ? kDefaultRelayDomain : other)),
          ],
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: const Scaffold(body: RelayDeniedNotice(serverId: 'abc')),
          ),
        ),
      ));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.text('Terms of use'));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();
      expect(find.text('Terms of Use'), findsOneWidget, reason: 'the Terms open');
      expect(find.byType(ForeignRelayTermsNotice),
          official ? findsNothing : findsOneWidget);
      if (!official) {
        expect(find.textContaining(kForeignRelayTermsTail, findRichText: true),
            findsOneWidget);
      }
    });
  }

  test('a call in a refused server or meeting is left, others are not', () {
    for (final (inside, refused, leaves) in [
      ('abc', 'ABC', true),
      ('conf:abc', 'conf:abc', true),
      ('abc', 'def', false),
    ]) {
      final voice = _FakeVoice(inside);
      final meetings = _FakeConference();
      final c = ProviderContainer(overrides: [
        voiceChannelProvider.overrideWith(() => voice),
        conferenceProvider.overrideWith(() => meetings),
      ]);
      addTearDown(c.dispose);
      final probe = Provider((ref) {
        leaveRefusedVoice(ref, refused);
        return 0;
      });
      c.read(probe);
      final meeting = inside.startsWith('conf:');
      expect(voice.left, leaves && !meeting, reason: '$inside / $refused voice');
      expect(meetings.left, leaves && meeting, reason: '$inside / $refused meeting');
    }
  });

  test('a refusal of one id matches it in any case', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(relayDeniedServersProvider.notifier).state = {'abc'};
    expect(c.read(serverRelayDeniedProvider('ABC')), isTrue);
    expect(c.read(serverRelayDeniedProvider('abd')), isFalse);
  });

  test('a pending join of a refused server says why', () {
    expect(pendingJoinTitle(rejected: false, denied: true), kPendingJoinDeniedTitle);
    expect(pendingJoinSubtitle(rejected: true, reason: 'x', denied: true), kServerDeniedText);
    expect(pendingJoinExplanation(rejected: false, reason: '', denied: true), kServerDeniedText);
    expect(pendingJoinTitle(rejected: false), 'Join request pending');
  });

  test('the copy carries no em dash and no colon', () {
    for (final s in [
      kServerDeniedText,
      kMeetingDeniedText,
      kDeniedKeepsText,
      kPendingJoinDeniedTitle,
      relayLoginDenialText('account_denied'),
      relayLoginDenialText('network_denied'),
      kRelayLoginDeniedTitle,
      kLoginDeniedStopsText,
      kRelayRefusedStatus,
      kForeignRelayTermsTail,
    ]) {
      expect(s.contains('—'), isFalse, reason: s);
      expect(s.contains(':'), isFalse, reason: s);
    }
  });

  testWidgets('the Classic user bar opens the refusal from its status line',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: _refused(true),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(width: 240, child: UserBar()),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(RelayDeniedDialog), findsNothing);
    await tester.tap(find.text(kRelayRefusedStatus));
    await tester.pumpAndSettle();
    expect(find.byType(RelayDeniedDialog), findsOneWidget);
  });

  for (final refused in [true, false]) {
    testWidgets(
        refused
            ? 'the phone status card opens the refusal, once however often tapped'
            : 'the phone status card takes no tap while merely offline',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: _refused(refused),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          // In the root overlay, above the dialog it opens, as in the app.
          home: const Scaffold(body: MobileConnectionIndicatorHost()),
        ),
      ));
      await tester.pump();
      await tester.pump(kConnectionIndicatorDelay);
      await tester.pump(const Duration(milliseconds: 300));
      final card = find.descendant(
          of: find.byType(MobileConnectionIndicator),
          matching: find.text(refused
              ? kRelayRefusedStatus
              : OverallConnection.offline.label));
      expect(card, findsOneWidget);
      await tester.tap(card, warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.tap(card, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(RelayDeniedDialog),
          refused ? findsOneWidget : findsNothing);
    });
  }
}

List<Override> _refused(bool refused) => hollowTestOverrides(extra: [
      overallConnectionProvider.overrideWithValue(
          refused ? OverallConnection.refused : OverallConnection.offline),
      relayLoginDenialProvider
          .overrideWith((_) => refused ? 'account_denied' : null),
    ]);

/// Listens for a refused login the way the shells do.
class _DenialHost extends ConsumerStatefulWidget {
  const _DenialHost();

  @override
  ConsumerState<_DenialHost> createState() => _DenialHostState();
}

class _DenialHostState extends ConsumerState<_DenialHost> {
  @override
  void initState() {
    super.initState();
    listenForRelayLoginDenial(ref, () => context);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _FakeVoice extends VoiceChannelNotifier {
  final String serverId;
  bool left = false;

  _FakeVoice(this.serverId);

  @override
  VoiceChannelState build() => const VoiceChannelState()
      .copyWith(currentServerId: serverId, currentChannelId: 'voice');

  @override
  Future<void> leaveChannel() async => left = true;
}

class _FakeConference extends ConferenceNotifier {
  bool left = false;

  @override
  ConferenceState build() => const ConferenceState();

  @override
  Future<void> leaveMeeting() async => left = true;
}

class _Domain extends RelayDomainNotifier {
  final String domain;

  _Domain(this.domain);

  @override
  String build() => domain;
}

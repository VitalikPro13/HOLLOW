// t14-denyproof wave 4: while this relay refuses the account, every surface
// that says our link is down says refused (never a reconnect away), what does
// not need the relay stays open, a refused server's voice room asks nothing,
// and destroying the identity everywhere warns before the confirm that the
// order cannot leave from here.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/link_down_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/components/connection_progress.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/relay_denied_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_connection_indicator.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_archive_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/settings/duress_section.dart';
import 'package:hollow/src/ui/settings/network_section.dart';
import 'package:hollow/src/ui/shell/bottom_bar.dart';
import 'package:hollow/src/ui/shell/conference_dashboard.dart';
import 'package:hollow/src/ui/shell/home_rail.dart';
import 'package:hollow/src/ui/shell/member_list.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';
import 'package:hollow/src/ui/shell/voice_room_switch.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

const _refusedTitle = 'This relay refused your account';

/// Our link: refused for the account, or plainly offline.
List<Override> _link({required bool refused, bool invisible = false}) => [
      overallConnectionProvider.overrideWithValue(
          refused ? OverallConnection.refused : OverallConnection.offline),
      relayLoginDenialProvider
          .overrideWith((_) => refused ? 'account_denied' : null),
      if (invisible) invisibleModeProvider.overrideWith(_Invisible.new),
    ];

class _Invisible extends InvisibleModeNotifier {
  @override
  bool build() => true;
}

Future<void> _pump(WidgetTester tester, Widget home,
    {required List<Override> extra, Size size = const Size(1280, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: hollowTestOverrides(extra: extra),
    child: MaterialApp(
      navigatorKey: hollowNavigatorKey,
      theme: HollowThemeData.dark(),
      home: home,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder _headerSays(String label) => find.descendant(
    of: find.byType(ConnectionProgress), matching: find.text(label));

const _members = [
  crdt_api.MemberFfi(
      peerId: kLocalPeerId,
      displayName: 'Me',
      role: 'owner',
      nickname: '',
      twitchUsername: '',
      labels: []),
];

void main() {
  setUpAll(() {
    RustLib.initMock(api: _Api());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  test('every down-link line names the refusal and promises no reconnect', () {
    for (final note in LinkNote.values) {
      final offline = linkDownNote(LinkDown.offline, note);
      for (final down in [LinkDown.refusedAccount, LinkDown.refusedNetwork]) {
        final refused = linkDownNote(down, note);
        expect(refused, isNot(offline), reason: '$note');
        expect(refused.toLowerCase(), isNot(contains('offline')), reason: '$note');
        expect(refused, isNot(contains("you're back")), reason: '$note');
        expect(refused, isNot(contains('Reconnect')), reason: '$note');
      }
      for (final s in [
        offline,
        linkDownNote(LinkDown.refusedAccount, note),
        linkDownNote(LinkDown.refusedNetwork, note),
      ]) {
        expect(s.contains('—'), isFalse, reason: s);
        expect(s.contains(':'), isFalse, reason: s);
      }
    }
    expect(linkDownNote(LinkDown.refusedAccount, LinkNote.title), _refusedTitle);
    expect(linkDownNote(LinkDown.refusedNetwork, LinkNote.title),
        'This relay blocks your network');
  });

  test('the meeting lobby promises no knock while the relay refuses us', () {
    final (_, note) = conferenceLobbyCopy(
        hostName: 'Ada', joining: false, down: LinkDown.refusedAccount);
    expect(note, linkDownNote(LinkDown.refusedAccount, LinkNote.lobby));
    final (_, carried) = conferenceLobbyCopy(hostName: 'Ada', joining: false);
    expect(carried, 'The host will let you in.');
  });

  test('the "you\'re offline" family has one source', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('link_down_provider.dart')) continue;
      if (f.readAsStringSync().contains("You're offline")) hits.add(f.path);
    }
    expect(hits, isEmpty, reason: 'say it through linkDownNote');
  });

  test('the refused status is its own header stage', () {
    expect(ConnectionStage.values, contains(ConnectionStage.refused));
  });

  group('refused account: every connection surface says refused', () {
    for (final refused in [true, false]) {
      final tag = refused ? 'refused' : 'offline';
      testWidgets('desktop channel header, $tag', (tester) async {
        final channel = testChannels[kChannelId1]!;
        await _pump(
            tester,
            Scaffold(
              body: ChannelChatPane(
                serverId: kServerId1,
                channelId: channel.channelId,
                channelName: channel.name,
              ),
            ),
            extra: [
              ..._link(refused: refused),
              serverMembersProvider(kServerId1)
                  .overrideWith((ref) async => _members),
            ]);
        expect(_headerSays(kRelayRefusedStatus),
            refused ? findsOneWidget : findsNothing);
        expect(_headerSays('Offline'), refused ? findsNothing : findsOneWidget);
        expect(
            find.descendant(
                of: find.byType(ConnectionProgress),
                matching: find.byIcon(LucideIcons.ban)),
            refused ? findsOneWidget : findsNothing);
      });

      testWidgets('phone channel header, $tag', (tester) async {
        final channel = testChannels[kChannelId1]!;
        await _pump(
            tester,
            MobileChatRoute(
              serverId: kServerId1,
              channelId: channel.channelId,
              channelName: channel.name,
            ),
            // The test font draws every glyph a full em wide.
            size: const Size(640, 800),
            extra: [
              ..._link(refused: refused),
              serverMembersProvider(kServerId1)
                  .overrideWith((ref) async => _members),
            ]);
        expect(_headerSays(kRelayRefusedStatus),
            refused ? findsOneWidget : findsNothing);
        expect(_headerSays('Offline'), refused ? findsNothing : findsOneWidget);
      });

      testWidgets('member list note, $tag', (tester) async {
        await _pump(tester, const Scaffold(body: MemberList(serverId: kServerId1)),
            size: const Size(260, 420),
            extra: [
              ..._link(refused: refused),
              serverMembersProvider(kServerId1)
                  .overrideWith((ref) async => _members),
            ]);
        expect(
            find.text(linkDownNote(
                refused ? LinkDown.refusedAccount : LinkDown.offline,
                LinkNote.presence)),
            findsOneWidget);
      });
    }

    testWidgets('a narrow phone channel header sheds the refused status',
        (tester) async {
      final channel = testChannels[kChannelId1]!;
      await _pump(
          tester,
          MobileChatRoute(
            serverId: kServerId1,
            channelId: channel.channelId,
            channelName: channel.name,
          ),
          size: const Size(320, 800),
          extra: [
            ..._link(refused: true),
            serverMembersProvider(kServerId1)
                .overrideWith((ref) async => _members),
          ]);
      expect(_headerSays(kRelayRefusedStatus), findsNothing);
      expect(tester.takeException(), isNull, reason: 'the title keeps its room');
    });

    testWidgets('phone status card shows the refusal mark, not a dead network',
        (tester) async {
      await _pump(tester, const Scaffold(body: MobileConnectionIndicatorHost()),
          size: const Size(400, 800), extra: _link(refused: true));
      await tester.pump(kConnectionIndicatorDelay);
      await tester.pump(const Duration(milliseconds: 300));
      final card = find.byType(MobileConnectionIndicator);
      expect(find.descendant(of: card, matching: find.byIcon(LucideIcons.ban)),
          findsOneWidget);
      expect(
          find.descendant(of: card, matching: find.byIcon(LucideIcons.wifiOff)),
          findsNothing);
    });

    testWidgets('phone status card while merely offline keeps the network mark',
        (tester) async {
      await _pump(tester, const Scaffold(body: MobileConnectionIndicatorHost()),
          size: const Size(400, 800), extra: _link(refused: false));
      await tester.pump(kConnectionIndicatorDelay);
      await tester.pump(const Duration(milliseconds: 300));
      final card = find.byType(MobileConnectionIndicator);
      expect(
          find.descendant(of: card, matching: find.byIcon(LucideIcons.wifiOff)),
          findsOneWidget);
    });

    testWidgets('phone Friends', (tester) async {
      await pumpHollowMobile(tester, extraOverrides: _link(refused: true));
      await _closeRefusalDialog(tester);
      await tester.tap(find.descendant(
          of: find.byType(MobileNavBar), matching: find.text('Friends')));
      await tester.pumpAndSettle();
      expect(find.byType(MobileFriendsTab), findsOneWidget);
      expect(find.text(_refusedTitle), findsOneWidget);
      expect(find.text("You're offline"), findsNothing);
    });

    testWidgets('phone voice room waiting to join', (tester) async {
      await _pump(
          tester,
          const MobileVoiceChannelRoute(
              serverId: kServerId1, channelId: kVoiceChannelId, channelName: 'Voice'),
          size: const Size(400, 800),
          extra: _link(refused: true));
      expect(find.text(_refusedTitle), findsOneWidget);
      expect(find.text("You're offline"), findsNothing);
      await tester.pump(const Duration(seconds: 30));
    });

    testWidgets('Home Active now', (tester) async {
      await _pump(tester, const Scaffold(body: HomeRail()),
          size: const Size(360, 1200), extra: _link(refused: true));
      expect(find.text(_refusedTitle), findsOneWidget);
      expect(
          find.text(linkDownNote(LinkDown.refusedAccount, LinkNote.friendsAround)),
          findsOneWidget);
    });

    testWidgets('Settings > Network says refused as a warning, like the dock',
        (tester) async {
      await _pump(
          tester,
          const Scaffold(
              body: SingleChildScrollView(child: RelaySettingsSection())),
          extra: _link(refused: true));
      final hollow = HollowTheme.of(tester.element(find.byType(Scaffold)));
      final spans = <TextSpan>[];
      for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
        rich.text.visitChildren((span) {
          if (span is TextSpan && span.text == kRelayRefusedStatus) {
            spans.add(span);
          }
          return true;
        });
      }
      expect(spans, isNotEmpty);
      for (final span in spans) {
        expect(span.style?.color, hollow.warning);
      }
    });
  });

  group('Invisible still shows a refusal', () {
    testWidgets('Classic user bar', (tester) async {
      await _pump(
          tester,
          const Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(width: 240, child: UserBar()),
            ),
          ),
          extra: _link(refused: true, invisible: true));
      expect(find.text('Invisible'), findsNothing);
      await tester.tap(find.text(kRelayRefusedStatus));
      await tester.pumpAndSettle();
      expect(find.byType(RelayDeniedDialog), findsOneWidget);
    });

    testWidgets('dock', (tester) async {
      await _pump(
          tester,
          const Scaffold(
              body: Align(alignment: Alignment.bottomCenter, child: BottomBar())),
          size: const Size(1400, 300),
          extra: _link(refused: true, invisible: true));
      expect(find.text('Invisible'), findsNothing);
      await tester.tap(find.text(kRelayRefusedStatus));
      await tester.pumpAndSettle();
      expect(find.byType(RelayDeniedDialog), findsOneWidget);
    });

    testWidgets('a carried link still reads Invisible', (tester) async {
      await _pump(
          tester,
          const Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: SizedBox(width: 240, child: UserBar()),
            ),
          ),
          extra: [
            overallConnectionProvider
                .overrideWithValue(OverallConnection.connected),
            invisibleModeProvider.overrideWith(_Invisible.new),
          ]);
      expect(find.text('Invisible'), findsOneWidget);
    });
  });

  group('refused account: Archive and Settings open', () {
    testWidgets('phone tab bar', (tester) async {
      await pumpHollowMobile(tester, extraOverrides: _link(refused: true));
      await _closeRefusalDialog(tester);
      for (final (label, page) in [
        ('Archive', MobileArchiveTab),
        ('Settings', MobileSettingsTab),
      ]) {
        await tester.tap(find.descendant(
            of: find.byType(MobileNavBar), matching: find.text(label)));
        await tester.pumpAndSettle();
        expect(find.byType(page), findsOneWidget, reason: label);
      }
    });

    testWidgets('dock', (tester) async {
      await _pump(
          tester,
          const Scaffold(
              body: Align(alignment: Alignment.bottomCenter, child: BottomBar())),
          size: const Size(1400, 300),
          extra: _link(refused: true));
      final c = ProviderScope.containerOf(tester.element(find.byType(BottomBar)));
      Finder place(String label) => find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == label);
      await tester.tap(place('Archive').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(openShellTabProvider), ShellTab.archive);
      await tester.tap(place('Settings').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(openShellTabProvider), ShellTab.settings);
    });

    testWidgets('the refused dialog says what keeps working', (tester) async {
      await _pump(tester, const Scaffold(body: RelayDeniedDialog(kind: 'account_denied')),
          extra: const []);
      expect(find.textContaining(kLoginDeniedWorksText), findsOneWidget);
      expect(find.textContaining(kDeniedKeepsText), findsOneWidget);
    });
  });

  group('desktop: a refused server\'s voice room', () {
    for (final (selected, words) in [
      (kServerId2, kVoiceDeniedShortText),
      (kServerId1, kServerDeniedText),
    ]) {
      testWidgets(
          selected == kServerId2
              ? 'asks nothing and keeps the current room, short beside its notice'
              : 'asks nothing and keeps the current room, in full elsewhere',
          (tester) async {
        await _pump(tester, const Scaffold(body: _SwitchProbe()), extra: [
          overallConnectionProvider
              .overrideWithValue(OverallConnection.connected),
          voiceChannelProvider.overrideWith(_InRoomWithPeople.new),
          selectedServerProvider.overrideWith((_) => selected),
          relayDeniedServersProvider
              .overrideWith((_) => {kServerId2.toLowerCase()}),
        ]);
        await tester.tap(find.text('join'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Switch voice room?'), findsNothing,
            reason: 'nothing to confirm');
        expect(_SwitchProbe.answer, isFalse);
        final c =
            ProviderScope.containerOf(tester.element(find.byType(_SwitchProbe)));
        expect(c.read(voiceChannelProvider).currentServerId, kServerId1,
            reason: 'still in A');
        expect(find.text(words), findsOneWidget);
        await tester.pump(const Duration(seconds: 5));
      });
    }

    testWidgets('a carried server still asks before leaving people behind',
        (tester) async {
      await _pump(tester, const Scaffold(body: _SwitchProbe()), extra: [
        overallConnectionProvider
            .overrideWithValue(OverallConnection.connected),
        voiceChannelProvider.overrideWith(_InRoomWithPeople.new),
        askBeforeVoiceSwitchProvider.overrideWith(_AskSwitch.new),
      ]);
      await tester.tap(find.text('join'));
      await tester.pumpAndSettle();
      expect(find.text('Switch voice room?'), findsOneWidget);
    });
  });

  group('destroy everywhere', () {
    for (final (refused, words) in [
      (true, linkDownNote(LinkDown.refusedAccount, LinkNote.destroyEverywhere)),
      (false, linkDownNote(LinkDown.offline, LinkNote.destroyEverywhere)),
    ]) {
      testWidgets(
          refused
              ? 'destroy everywhere warns while the relay refuses'
              : 'destroy everywhere warns while offline',
          (tester) async {
        await _pumpDangerZone(tester, _link(refused: refused));
        await tester.tap(find.text('Destroy identity'));
        await tester.pumpAndSettle();
        expect(find.text(words), findsOneWidget,
            reason: 'said before the confirm');
        expect(find.textContaining('holds it for up to a year'), findsNothing,
            reason: 'no promise the order cannot keep');
        // The local wipe is offered exactly as before.
        await tester.enterText(find.byType(TextField).last, 'DESTROY');
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<HollowButton>(find.widgetWithText(HollowButton, 'Destroy'))
                .onPressed,
            isNotNull);
        // Unlinking this device cannot leave either.
        await tester.tap(find.text('This device and unlink it'));
        await tester.pumpAndSettle();
        expect(
            find.text(linkDownNote(
                refused ? LinkDown.refusedAccount : LinkDown.offline,
                LinkNote.destroyUnlink)),
            findsOneWidget);
      });
    }

    testWidgets('destroy everywhere keeps its delivery promise while connected',
        (tester) async {
      await _pumpDangerZone(tester, [
        overallConnectionProvider.overrideWithValue(OverallConnection.connected),
      ]);
      await tester.tap(find.text('Destroy identity'));
      await tester.pumpAndSettle();
      expect(find.textContaining('holds it for up to a year'), findsOneWidget);
      expect(
          find.text(
              linkDownNote(LinkDown.offline, LinkNote.destroyEverywhere)),
          findsNothing);
    });
  });
}

Future<void> _closeRefusalDialog(WidgetTester tester) async {
  if (find.byType(RelayDeniedDialog).evaluate().isEmpty) return;
  await tester.tapAt(const Offset(4, 4));
  await tester.pumpAndSettle();
}

Future<void> _pumpDangerZone(WidgetTester tester, List<Override> link) =>
    _pump(
        tester,
        const Scaffold(
            body: SingleChildScrollView(
                child: Padding(
                    padding: EdgeInsets.all(16),
                    child: AccountDangerZoneCard()))),
        size: const Size(500, 1200),
        extra: [
          ...link,
          rosterStatusProvider.overrideWith((ref) async => const roster_api.RosterStatus(
                member: true,
                protected: false,
                backupWait: true,
                devices: [],
              )),
        ]);

/// In voice room A with someone else, so a switch would ask.
class _InRoomWithPeople extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        currentServerId: kServerId1,
        currentChannelId: 'a',
        currentChannelName: 'A',
        participants: {
          kServerId1: {
            'a': {'someone-else'},
          },
        },
      );
}

class _AskSwitch extends AskBeforeVoiceSwitchNotifier {
  @override
  Future<bool> build() async => true;
}

class _SwitchProbe extends ConsumerWidget {
  const _SwitchProbe();

  static bool? answer;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
        child: TextButton(
          onPressed: () async {
            answer = null;
            answer = await confirmVoiceRoomSwitch(context, ref,
                serverId: kServerId2, channelId: 'b', channelName: 'B');
          },
          child: const Text('join'),
        ),
      );
}

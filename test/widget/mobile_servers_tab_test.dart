import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/name_text.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_switcher.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_route.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_page.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_order.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_servers_tab.dart';

import '../helpers/mobile_servers_fixture.dart';
import '../helpers/test_app.dart';

/// #154: the phone's Servers tab (dock order, folders, badges, parked joins,
/// empty and error states) and the Chats tab without servers, whose header
/// opens the Archive page.
Finder _inServers(Finder f) =>
    find.descendant(of: find.byType(MobileServersTab), matching: f);
Finder _inChats(Finder f) =>
    find.descendant(of: find.byType(MobileChatsTab), matching: f);

Future<void> _openServersTab(WidgetTester tester) async {
  await tester.tap(find.descendant(
      of: find.byType(MobileNavBar), matching: find.text('Servers')));
  await tester.pumpAndSettle();
}

/// The row (a pressable with a composed label) that holds [text].
Finder _rowOf(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byWidgetPredicate((w) => w is Semantics &&
          (w.properties.label ?? '').startsWith(text)),
    );

class _NoServers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => const {};
}

class _NoPending extends PendingJoinsNotifier {
  @override
  Map<String, PendingJoinInfo> build() => const {};
}

void main() {
  group('Servers tab', () {
    testWidgets('lists servers in dock order, a folder as a header over its own',
        (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: mobileServersFixture());
      await _openServersTab(tester);

      final order = [
        'Pixel Guild',
        'Work stuff',
        'Book Club',
        'Synth Lab',
        'Night Owls',
        'Join request pending',
      ];
      final ys = [
        for (final t in order) tester.getTopLeft(_inServers(find.text(t))).dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]),
            reason: '${order[i]} comes after ${order[i - 1]}');
      }
      expect(find.text('Hidden Place'), findsNothing,
          reason: 'a server the age gate hides never shows');
    });

    testWidgets('a mention outranks unread; a muted server shows no count',
        (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: mobileServersFixture());
      await _openServersTab(tester);

      expect(find.descendant(of: _rowOf('Pixel Guild'), matching: find.text('@2')),
          findsOneWidget);
      expect(find.descendant(of: _rowOf('Synth Lab'), matching: find.text('3')),
          findsOneWidget);
      expect(find.descendant(of: _rowOf('Night Owls'), matching: find.text('Muted')),
          findsOneWidget);
      expect(find.descendant(of: _rowOf('Night Owls'), matching: find.text('9')),
          findsNothing);
      expect(_inServers(find.text('1 member')), findsOneWidget);
      expect(_inServers(find.text('48 members')), findsOneWidget);
    });

    testWidgets('a voice room with people names it and how many',
        (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: mobileServersFixture());
      await _openServersTab(tester);
      expect(_inServers(find.text('3 in Lounge')), findsOneWidget);
      expect(_inServers(find.text('12 members')), findsNothing,
          reason: 'one line: the room while people are in it');
    });

    testWidgets('a tap opens the server; a long press its actions',
        (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: mobileServersFixture());
      await _openServersTab(tester);
      await tester.longPress(_inServers(find.text('Pixel Guild')));
      await tester.pumpAndSettle();
      expect(find.text('Mark as read'), findsOneWidget);
      await tester.tapAt(const Offset(195, 40));
      await tester.pumpAndSettle();

      await tester.tap(_inServers(find.text('Pixel Guild')));
      await tester.pumpAndSettle();
      expect(find.byType(MobileServerRoute), findsOneWidget);
    });

    testWidgets('a parked join opens its sheet from here', (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: mobileServersFixture());
      await _openServersTab(tester);
      await tester.tap(_inServers(find.text('Join request pending')));
      await tester.pumpAndSettle();
      expect(find.text('Copy invite link'), findsOneWidget);
    });

    testWidgets('no servers: one honest line and a way to add one',
        (tester) async {
      await pumpHollowMobile(tester, extraOverrides: [
        serverListProvider.overrideWith(_NoServers.new),
        pendingJoinsProvider.overrideWith(_NoPending.new),
      ]);
      await _openServersTab(tester);
      expect(_inServers(find.text('No servers yet')), findsOneWidget);
      expect(_inServers(find.text('Add a server')), findsOneWidget);
    });

    testWidgets('servers held back by the age gate are no "none yet"',
        (tester) async {
      await pumpHollowMobile(tester, extraOverrides: [
        serverListProvider.overrideWith(_NoServers.new),
        pendingJoinsProvider.overrideWith(_NoPending.new),
        ageHoldHidesServersProvider.overrideWithValue(true),
      ]);
      await _openServersTab(tester);
      expect(_inServers(find.text(kAgeHoldNoticeText)), findsOneWidget);
      expect(_inServers(find.text('No servers yet')), findsNothing);
    });

    testWidgets('a list that failed to read says so, never "none yet"',
        (tester) async {
      await pumpHollowMobile(tester, extraOverrides: [
        serverListProvider.overrideWith(_NoServers.new),
        pendingJoinsProvider.overrideWith(_NoPending.new),
        serverListLoadStateProvider
            .overrideWith((_) => (loaded: false, error: StateError('disk'))),
      ]);
      await _openServersTab(tester);
      expect(_inServers(find.text("Your servers didn't load")), findsOneWidget);
      expect(_inServers(find.text('Try again')), findsOneWidget);
      expect(_inServers(find.text('No servers yet')), findsNothing);
    });

    for (final scale in const [1.0, 1.5, 2.0]) {
      for (final width in const [320.0, 390.0]) {
        testWidgets('fits at ${scale}x text, $width wide', (tester) async {
          await pumpHollowMobile(tester,
              viewportSize: Size(width, 800),
              textScaler: TextScaler.linear(scale),
              extraOverrides: mobileServersFixture());
          await _openServersTab(tester);
          expect(find.byType(MobileServersTab), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('Servers tab entries', () {
    test('a folder ends before a loose server; leftovers come last, by name',
        () {
      final entries = mobileServersEntries(
        layout: kFixtureLayout,
        listed: {
          kSrvBeta: 'b',
          kSrvAlpha: 'a',
          kSrvFolded: 'f',
          kSrvMuted: 'm',
          'srv_zed': 'Zed',
          'srv_new': 'new one',
        },
        pending: [kSrvPending, 'srv_parked_late', kSrvBeta],
      );
      String show(MobileServersEntry e) => switch (e) {
            MobileServersFolder(:final name) => 'folder:$name',
            MobileServersFolderEnd() => 'end',
            MobileServersServer(:final serverId) => serverId,
            MobileServersPending(:final serverId) => 'pending:$serverId',
          };
      expect(entries.map(show), [
        kSrvBeta,
        'folder:Work stuff',
        kSrvFolded,
        kSrvAlpha,
        'end',
        kSrvMuted,
        'pending:$kSrvPending',
        'srv_new',
        'srv_zed',
        'pending:srv_parked_late',
      ]);
    });

    test('a folder with nothing listed draws no header', () {
      final entries = mobileServersEntries(
        layout: kFixtureLayout,
        listed: {kSrvBeta: 'b'},
        pending: const [],
      );
      expect(entries.whereType<MobileServersFolder>(), isEmpty);
      expect(entries.whereType<MobileServersFolderEnd>(), isEmpty);
    });
  });

  group('Switcher sheet', () {
    Future<void> openSwitcher(WidgetTester tester) async {
      await _openServersTab(tester);
      showMobileServerSwitcher(
          tester.element(find.byType(MobileServersTab)), kSrvBeta);
      await tester.pumpAndSettle();
      expect(find.text('Your servers'), findsOneWidget);
    }

    // The sheet's rows are list rows; the tab's are not.
    Finder inSheet(Finder f) =>
        find.descendant(of: find.byType(HollowListRow), matching: f);

    // Review L3: the sheet and the tab say the same about a muted server.
    testWidgets('a muted server reads as on the tab: no count, faded',
        (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: [
            ...mobileServersFixture(),
            unreadProvider.overrideWith(() => FixtureUnread(const UnreadState(
                  channelLastSeen: {},
                  dmLastSeen: {},
                  channelUnreadCounts: {'$kSrvMuted:$kSrvGeneralId': 9},
                  dmUnreadCounts: {},
                  channelLatestId: {},
                  dmLatestId: {},
                  channelMentionCounts: {'$kSrvMuted:$kSrvGeneralId': 5},
                ))),
          ]);
      await openSwitcher(tester);
      expect(inSheet(find.text('Night Owls')), findsOneWidget);
      expect(inSheet(find.text('Muted')), findsOneWidget);
      expect(inSheet(find.text('@5')), findsNothing,
          reason: 'the tab counts nothing for a muted server');
      expect(inSheet(find.text('9')), findsNothing);
      final hollow = HollowTheme.of(tester.element(find.text('Your servers')));
      final name = tester.widget<NameText>(inSheet(find.byWidgetPredicate(
          (w) => w is NameText && w.text == 'Night Owls')));
      expect(name.paint.stops, [hollow.textTertiary]);
    });

    // Review L15: one dock order for the tab and the sheet.
    testWidgets("lists servers in the tab's order and hides what it hides",
        (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: mobileServersFixture());
      await openSwitcher(tester);
      final order = ['Pixel Guild', 'Book Club', 'Synth Lab', 'Night Owls'];
      final ys = [
        for (final t in order) tester.getTopLeft(inSheet(find.text(t))).dy,
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: order[i]);
      }
      expect(inSheet(find.text('Hidden Place')), findsNothing);
    });
  });

  group('Chats tab', () {
    testWidgets('servers left; channels that mention you stay under Mentions',
        (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(390, 1200),
          extraOverrides: mobileServersFixture());
      for (final name in ['Pixel Guild', 'Synth Lab', 'Book Club']) {
        expect(_inChats(find.text(name)), findsNothing, reason: name);
      }
      await tester.tap(_inChats(find.text('Mentions')));
      await tester.pumpAndSettle();
      expect(_inChats(find.text('#general')), findsOneWidget);
      expect(_inChats(find.text('Pixel Guild')), findsOneWidget,
          reason: 'the mention row names its server');
    });

    testWidgets('the header opens the Archive page, fresh on every visit',
        (tester) async {
      var reads = 0;
      await pumpHollowMobile(tester, extraOverrides: [
        archiveDmListProvider.overrideWith((ref) async {
          reads++;
          return const [];
        }),
        archiveChannelListProvider.overrideWith((ref) async => const []),
      ]);
      expect(find.descendant(
          of: find.byType(MobileNavBar), matching: find.text('Archive')),
          findsNothing, reason: 'Archive is no tab now');

      for (var visit = 1; visit <= 2; visit++) {
        await tester.tap(_inChats(find.bySemanticsLabel('Archive')));
        await tester.pumpAndSettle();
        expect(find.byType(MobileArchivePage), findsOneWidget);
        expect(reads, visit, reason: 'counts are read again on visit $visit');
        await tester.tap(find.bySemanticsLabel('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(MobileArchivePage), findsNothing);
      }
    });
  });
}

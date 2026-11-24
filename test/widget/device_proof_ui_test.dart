/// The device-proof screens (DEVICE_PROOF_DESIGN 8.3, 8.4, 8.8, appendix A):
/// the owner's lost-device review, the restore chooser and the recovery
/// banners, against fixtures while track C1's FFI answers empty.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/server_recovery_notices.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/dialogs/restore_chooser.dart';
import 'package:hollow/src/ui/server_settings/pages/lost_devices_page.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/core/providers/server_provider.dart' show Permission;
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/device_proof_fixtures.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Records the two answers; every other call stays pending.
class _Api implements RustLibApi {
  final answers = <List<Object?>>[];
  final restores = <List<Object?>>[];

  @override
  Future<dp.RefoldApplied> crateApiDeviceProofAnswerRefoldReview({
    required String serverId,
    required String member,
    required String device,
    String? below,
    required List<String> chosen,
    required List<String> putBack,
  }) async {
    answers.add([serverId, member, device, below, chosen, putBack]);
    return refoldAppliedFor(chosen, putBack);
  }

  @override
  Future<void> crateApiDeviceProofChooseRestore(
          {required String serverId, String? cp}) async =>
      restores.add([serverId, cp]);

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

final _api = _Api();

String _same(String s) => s;

Future<void> _pump(WidgetTester tester, Widget child,
    {List<Override> overrides = const [],
    Size size = const Size(1000, 1600),
    bool touch = false}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: overrides),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: SettingsDensity(
          touch: touch,
          child: SingleChildScrollView(child: child),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

bool _toggleOn(WidgetTester tester, String key) => tester
    .widget<HollowToggle>(find.descendant(
        of: find.byKey(ValueKey(key)), matching: find.byType(HollowToggle)))
    .value;

HollowButton _button(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(HollowButton)));

Future<void> _openChooser(WidgetTester tester, dp.Restores restores,
    {Size size = const Size(1000, 1400),
    bool fresh = false,
    Map<String, ServerInfo>? servers}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides:
        hollowTestOverrides(
            extra: deviceProofOverrides(restores: restores, servers: servers)),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
              onPressed: () => showRestoreChooser(context, fresh: fresh),
              child: const Text('open')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _api));
  setUp(() {
    _api.answers.clear();
    _api.restores.clear();
  });

  group('copy', () {
    test('names the first two supporters and counts the rest', () {
      expect(namesLine(['A']), 'A');
      expect(namesLine(['A', 'B']), 'A and B');
      expect(namesLine(['A', 'B', 'C']), 'A, B and 1 other');
      expect(namesLine(['A', 'B', 'C', 'D', 'E']), 'A, B and 3 others');
    });

    test('carries no em dash and no colon standing in for one', () {
      final src = File('lib/src/core/device_proof_copy.dart').readAsStringSync();
      expect(src.contains('—'), isFalse);
      const names = RefoldNames(
          server: 'S',
          member: 'M',
          person: _same,
          unnamedPerson: _same,
          channel: _same,
          label: _same,
          role: _same);
      final lines = <String>[
        refoldIntro('M'),
        refoldApplied('S'),
        refoldKept('S'),
        keepAllMessage(total: 7, picked: 3),
        keepAllMessage(total: 1, picked: 1),
        refoldChangedSince('A was banned'),
        putBackChangedSince('#c'),
        kRestoreNothing,
        refoldNotice(['A', 'B'], 'S'),
        shellBanner('A', 'S'),
        steppedBackBanner('S'),
        restorePick('S', 'd', ['A']),
        restorePoints('S'),
        kRestoreUnknownServers,
        kRestoreDontKnowNote,
      ];
      for (final k in dp.RefoldItemKind.values) {
        for (final opens in [false, true]) {
          final t = refoldItemText(
              dp.RefoldItem(
                  key: 'k',
                  group: dp.RefoldGroup.other,
                  kind: k,
                  target: 'T',
                  channelId: 'c',
                  labelId: 'l',
                  role: 'admin',
                  oldRole: 'member',
                  opens: opens),
              names);
          lines.add(t.line);
          if (t.opens != null) lines.add(t.opens!);
        }
      }
      for (final l in lines) {
        expect(l.contains(': ') || l.contains('—'), isFalse, reason: l);
      }
    });

    test('a fallback server name opens a sentence capitalized', () {
      expect(restoreDone(kRestoreServerFallback), 'Your server is restored.');
      expect(restoreDone('iOS devs'), 'iOS devs is restored.');
    });
  });

  group('lost device review', () {
    testWidgets(
        'refold_review_starts_with_nothing_selected_and_names_what_each_undo_opens',
        (tester) async {
      await _pump(tester, const LostDevicesPage(serverId: kServerId1),
          overrides: deviceProofOverrides(reviews: fixtureReviews));

      expect(find.text("Changes from Mira's lost device"), findsOneWidget);
      for (final key in [
        'k-ban', 'k-join', 'k-role', 'k-mute', 'k-public', 'k-joinrules', //
        'k-deleted'
      ]) {
        expect(_toggleOn(tester, 'refold-item-$key'), isFalse, reason: key);
      }
      expect(_toggleOn(tester, 'put-back-$kChannelId1'), isFalse);
      expect(_button(tester, 'Apply selected').onPressed, isNull);

      // What each undo opens, in the words of appendix A.
      expect(
          find.text('Tomas was banned. Undoing lifts the ban and brings Tomas '
              'back as Moderator.'),
          findsOneWidget);
      expect(
          find.text('Anyone, including people outside Test Server, can then '
              'read new posts there.'),
          findsOneWidget);
      expect(find.text('More people can then join Test Server.'), findsOneWidget);
      expect(
          find.text('A channel was deleted. Undoing brings a channel back for '
              'admins only. You can open it to others again afterwards.'),
          findsOneWidget);
      expect(find.text('Ilse became Admin. Undoing makes Ilse a member again.'),
          findsOneWidget);

      // Groups in appendix A order, "Already undone" first.
      final order = [
        kAlreadyUndoneHeading,
        'Members removed or banned',
        'People it let in',
        'Roles',
        'Mutes',
        'Who can see or post',
        'Joining the server',
        'Channels, labels, emotes and stickers',
      ].map((t) => tester.getTopLeft(find.text(t)).dy).toList();
      expect([...order]..sort(), order);

      expect(find.text('3 more changes come up after you answer these.'),
          findsOneWidget);
      expect(
          find.text('1 more member reported a lost device. Their changes come '
              'up after you answer these.'),
          findsOneWidget);
      expect(find.text('Answered on Desktop.'), findsOneWidget);
      // The owner's checkpoint applied it: two undone, one kept.
      expect(find.text('Hollow undid 2 changes. 1 stayed.'), findsOneWidget);
      expect(find.text(kRefoldTimedOut), findsOneWidget);
    });

    testWidgets('an answer the checkpoint has not applied yet says so',
        (tester) async {
      await _pump(tester, const LostDevicesPage(serverId: kServerId1),
          overrides: deviceProofOverrides(
              reviews: const dp.RefoldReviews(reviews: [
            dp.RefoldReview(
                member: kTomas,
                device: 'device_tomas_desk_000000000001',
                dr: 'dr02',
                listed: true,
                unpublished: [],
                items: [],
                moreItems: 0,
                answered: dp.RefoldAnswered(
                    byDevice: kOwnDesktop,
                    timeout: false,
                    undone: [],
                    kept: [])),
          ], moreReports: 0)));
      expect(find.text('Answered on Desktop.'), findsOneWidget);
      expect(find.text(refoldApplied('Test Server')), findsOneWidget);
      expect(find.textContaining('Hollow undid'), findsNothing);
    });

    test('an answer\'s outcome counts what was undone and what stayed', () {
      expect(refoldOutcome(undone: 1, kept: 0), 'Hollow undid 1 change.');
      expect(refoldOutcome(undone: 3, kept: 1), 'Hollow undid 3 changes. 1 stayed.');
      expect(refoldOutcome(undone: 0, kept: 4), 'These changes stayed.');
    });

    test('a role change reads the new role, and its undo the role it had', () {
      // `role` = what an undo gives back, `oldRole` = what the lost device gave.
      final line = refoldItemText(
              const dp.RefoldItem(
                  key: 'k',
                  group: dp.RefoldGroup.roles,
                  kind: dp.RefoldItemKind.roleChanged,
                  target: 'T',
                  role: 'moderator',
                  oldRole: 'admin',
                  opens: true),
              RefoldNames(
                server: 'S',
                member: 'Mira',
                person: (_) => 'Ilse',
                unnamedPerson: (m) => m,
                channel: (_) => null,
                label: (_) => null,
                role: (r) => r,
              ))
          .line;
      expect(line, 'Ilse became admin. Undoing makes Ilse moderator again.');
    });

    testWidgets('Put back names what it opens once on', (tester) async {
      await _pump(tester, const LostDevicesPage(serverId: kServerId1),
          overrides: deviceProofOverrides(reviews: fixtureReviews));
      final opens = find.text(putBackOpens('Test Server'));
      expect(opens, findsOneWidget); // the stopped-public item only
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('put-back-$kChannelId1')),
          matching: find.byType(HollowToggle)));
      await tester.pump();
      expect(opens, findsNWidgets(2));
      expect(_button(tester, 'Apply selected').onPressed, isNotNull);
    });

    testWidgets('Apply selected sends exactly the chosen items', (tester) async {
      await _pump(tester, const LostDevicesPage(serverId: kServerId1),
          overrides: deviceProofOverrides(reviews: fixtureReviews));
      await tester.tap(find.descendant(
          of: find.byKey(const ValueKey('refold-item-k-ban')),
          matching: find.byType(HollowToggle)));
      await tester.pump();
      await tester.tap(find.text('Apply selected'));
      await tester.pump();
      expect(_api.answers, [
        [kServerId1, kMira, fixtureOpenReview.device, null, ['k-ban'], <String>[]],
      ]);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('Select all picks every item and never a Put back',
        (tester) async {
      await _pump(tester, const LostDevicesPage(serverId: kServerId1),
          overrides: deviceProofOverrides(reviews: fixtureReviews));
      await tester.tap(find.text('Select all'));
      await tester.pump();
      for (final i in fixtureOpenReview.items) {
        expect(_toggleOn(tester, 'refold-item-${i.key}'), isTrue, reason: i.key);
      }
      expect(_toggleOn(tester, 'put-back-$kChannelId1'), isFalse);
    });

    testWidgets('Keep all answers with nothing undone', (tester) async {
      await _pump(tester, const LostDevicesPage(serverId: kServerId1),
          overrides: deviceProofOverrides(reviews: fixtureReviews));
      await tester.tap(find.text('Keep all'));
      await tester.pump();
      expect(_api.answers.single.sublist(4), [<String>[], <String>[]]);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('the page holds at phone width with touch rows',
        (tester) async {
      await _pump(tester, const LostDevicesPage(serverId: kServerId1),
          overrides: deviceProofOverrides(reviews: fixtureReviews),
          size: const Size(320, 3600),
          touch: true);
      expect(tester.takeException(), isNull);
      expect(find.text('Apply selected'), findsOneWidget);
    });

    test('the page shows only while the owner has reviews', () {
      expect(serverSettingsPagesFor(Permission.all),
          isNot(contains(ServerSettingsPage.lostDevices)));
      expect(serverSettingsPagesFor(Permission.all, lostDevices: true),
          contains(ServerSettingsPage.lostDevices));
      expect(hasRefoldReviews(const dp.RefoldReviews(reviews: [], moreReports: 0)),
          isFalse);
      expect(hasRefoldReviews(fixtureReviews), isTrue);
      expect(openRefoldReviews(fixtureReviews), [fixtureOpenReview]);
    });
  });

  group('banners', () {
    testWidgets('nothing shows while the node answers empty', (tester) async {
      await _pump(tester, const ServerRecoveryNotices(serverId: kServerId1),
          overrides: deviceProofOverrides());
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a server its owner restores says so', (tester) async {
      await _pump(tester, const ServerRecoveryNotices(serverId: kServerId1),
          overrides: deviceProofOverrides(
              recovery: const dp.ServerRecovery(steppedBack: true)));
      expect(find.text(steppedBackBanner('Test Server')), findsOneWidget);
    });

    testWidgets('a member removed meanwhile sees who and can leave',
        (tester) async {
      await _pump(tester, const ServerRecoveryNotices(serverId: kServerId1),
          overrides: deviceProofOverrides(
              recovery:
                  const dp.ServerRecovery(steppedBack: true, removedBy: kTomas)));
      expect(find.text(shellBanner('Tomas', 'Test Server')), findsOneWidget);
      expect(find.text(steppedBackBanner('Test Server')), findsNothing);
      expect(find.text('Leave Test Server'), findsOneWidget);
    });

    testWidgets('the owner is asked to review, on a phone too', (tester) async {
      await _pump(
          tester, const ServerRecoveryNotices(serverId: kServerId1, touch: true),
          overrides: deviceProofOverrides(reviews: fixtureReviews),
          size: const Size(320, 600));
      expect(
          find.text('Mira reported a lost device. Some changes it made in '
              'Test Server need your decision.'),
          findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('restore chooser', () {
    testWidgets('a pick names its supporters and offers another point',
        (tester) async {
      await _openChooser(tester, fixtureRestores([dp.RestoreStage.pick]));
      expect(find.textContaining('Confirmed by Mira, Tomas and 1 other.'),
          findsOneWidget);
      expect(find.text(kRestorePickNote), findsOneWidget);
      await tester.tap(find.text('Choose another point'));
      await tester.pump();
      expect(find.text(restorePoints('Test Server')), findsOneWidget);
      expect(find.text(kRestoreDontKnow), findsOneWidget);
    });

    testWidgets('the dated list starts with nothing chosen', (tester) async {
      await _openChooser(tester, fixtureRestores([dp.RestoreStage.points]));
      expect(find.text(restorePoints('Dev Hangout')), findsOneWidget);
      expect(find.text('Before the 0.14 update'), findsOneWidget);
      expect(find.text('Named by Mira, Tomas and 2 others'), findsOneWidget);
      final rows = tester.widgetList<HollowListRow>(find.byType(HollowListRow));
      expect(rows.length, 4);
      expect(rows.any((r) => r.selected), isFalse);
      expect(_button(tester, 'Restore').onPressed, isNull);
      await tester.tap(find.text(kRestoreDontKnow));
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pump();
      expect(_api.restores, [
        [kServerId2, null],
      ]);
    });

    testWidgets('too few answers names the one member', (tester) async {
      await _openChooser(tester, fixtureRestores([dp.RestoreStage.onlyOne]));
      expect(find.text(restoreOnlyOne('Ilse', 'Test Server')), findsOneWidget);
    });

    testWidgets('the waiting stages say whom Hollow asks', (tester) async {
      await _openChooser(
          tester,
          fixtureRestores([
            dp.RestoreStage.checking,
          ]));
      expect(find.text(restoreChecking('Test Server')), findsOneWidget);
    });

    testWidgets('a server no member named a point for waits, never offering "I don\'t know"',
        (tester) async {
      await _openChooser(
          tester, fixtureRestores([dp.RestoreStage.waitingForMember]));
      expect(find.text(restoreWaitingForMember('Test Server')), findsOneWidget);
      expect(find.text(kRestoreDontKnow), findsNothing);
      expect(find.text('Restore'), findsNothing);
    });

    testWidgets('no known server asks for an invite', (tester) async {
      await _openChooser(
          tester, const dp.Restores(serversKnown: false, servers: []),
          fresh: true,
          servers: const {});
      expect(find.text(kRestoreUnknownServers), findsOneWidget);
    });

    test('offered after a recovery only when it has something to say', () {
      const unknown = dp.Restores(serversKnown: false, servers: []);
      expect(restoreChooserDue(unknown, fresh: true, holdsServers: false),
          isTrue);
      expect(restoreChooserDue(unknown, fresh: true, holdsServers: true),
          isFalse);
      // A device that already held state never hears it lost its servers.
      expect(restoreChooserDue(unknown, fresh: false, holdsServers: false),
          isFalse);
      expect(
          restoreChooserDue(fixtureRestores([dp.RestoreStage.done]),
              fresh: true, holdsServers: true),
          isFalse);
      expect(
          restoreChooserDue(fixtureRestores([dp.RestoreStage.checking]),
              fresh: false, holdsServers: true),
          isTrue);
    });
  });
}

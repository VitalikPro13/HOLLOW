/// Regressions from the UI review of the device-proof screens (track C2, fix
/// round): stale restore picks, the chooser under a lock, Keep all, deleted
/// names, the answer's outcome, the unknown-servers stage, the start offers,
/// the Leave button, phone targets, stale providers and the copy.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/peer_id_label.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/server_recovery_notices.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/dialogs/restore_chooser.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/server_settings/pages/lost_devices_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/device_proof_fixtures.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

class _Api implements RustLibApi {
  final answers = <List<Object?>>[];
  final restores = <List<Object?>>[];
  var restoreReads = 0;

  /// Keys and channel ids the next answer reports as changed since.
  var changedSince = <String>{};

  @override
  Future<dp.RefoldApplied> crateApiDeviceProofAnswerRefoldReview({
    required String serverId,
    required String member,
    required String device,
    String? below,
    required List<String> chosen,
    required List<String> putBack,
  }) async {
    answers.add([chosen, putBack]);
    return refoldAppliedFor(chosen, putBack, changedSince: changedSince);
  }

  @override
  Future<void> crateApiDeviceProofChooseRestore(
          {required String serverId, String? cp}) async =>
      restores.add([serverId, cp]);

  @override
  Future<dp.Restores> crateApiDeviceProofRestoreChoices() async {
    restoreReads++;
    return const dp.Restores(serversKnown: true, servers: []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

final _api = _Api();

dp.Restores _points(List<String> cps,
        {dp.RestoreStage stage = dp.RestoreStage.points}) =>
    dp.Restores(serversKnown: true, servers: [
      dp.RestoreChoices(
        serverId: kServerId2,
        stage: stage,
        points: [
          for (final cp in cps)
            dp.RestorePoint(
                cp: cp,
                dateMs: 1762300000000,
                namedBy: [kMira],
                namedByNames: [null]),
        ],
      ),
    ]);

HollowButton _button(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(HollowButton)));

Future<void> _openChooser(
  WidgetTester tester, {
  required dp.Restores Function() restores,
  Size size = const Size(1000, 1400),
  bool fresh = false,
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      ...deviceProofOverrides(),
      ...extra,
      restoreChoicesProvider.overrideWith((_) async => restores()),
    ]),
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

Future<void> _pumpPage(WidgetTester tester,
    {required List<Override> overrides, bool touch = false}) async {
  tester.view.physicalSize = const Size(1000, 2400);
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
          child: const SingleChildScrollView(
              child: LostDevicesPage(serverId: kServerId1)),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _toggle(WidgetTester tester, String key) async {
  await tester.tap(find.descendant(
      of: find.byKey(ValueKey(key)), matching: find.byType(HollowToggle)));
  await tester.pump();
}

dp.RefoldReview _review(List<dp.RefoldItem> items,
        {String member = kMira, String device = 'device_x_0000000000000001'}) =>
    dp.RefoldReview(
      member: member,
      device: device,
      dr: 'dr09',
      listed: true,
      unpublished: const [],
      items: items,
      moreItems: 0,
    );

/// The roster gate under the test's control.
class _Gate extends RosterGateNotifier {
  final RosterGate first;
  _Gate(this.first);
  @override
  RosterGate build() => first;
  void set(RosterGate g) => state = g;
}

class _NoServers extends ServerListNotifier {
  @override
  build() => const {};
}

Future<void> _pumpBanner(
  WidgetTester tester, {
  dp.ServerRecovery recovery =
      const dp.ServerRecovery(steppedBack: true, removedBy: kTomas),
  dp.RefoldReviews? reviews,
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = const Size(1000, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      ...deviceProofOverrides(recovery: recovery, reviews: reviews),
      ...extra,
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const Scaffold(
          body: SingleChildScrollView(
              child: ServerRecoveryNotices(serverId: kServerId1))),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// The real channel chat, desktop pane or phone page, in a fresh scope.
Future<void> _pumpChat(WidgetTester tester,
    {required bool phone, required dp.ServerRecovery recovery}) async {
  tester.view.physicalSize = phone ? const Size(400, 800) : const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final channel = testChannels[kChannelId1]!;
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: hollowTestOverrides(extra: [
      ...deviceProofOverrides(recovery: recovery),
      selectedServerProvider.overrideWith((_) => kServerId1),
      selectedChannelProvider.overrideWith((_) => kChannelId1),
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

void main() {
  setUpAll(() {
    RustLib.initMock(api: _api);
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });
  setUp(() {
    _api.answers.clear();
    _api.restores.clear();
    _api.restoreReads = 0;
  });

  group('restore chooser picks', () {
    testWidgets('a pick that vanished on a poll restores nothing',
        (tester) async {
      var current = _points(['cp-a', 'cp-b']);
      await _openChooser(tester, restores: () => current);
      await tester.tap(find.byKey(const ValueKey('restore-point-$kServerId2-cp-b')));
      await tester.pump();
      expect(_button(tester, 'Restore').onPressed, isNotNull);
      // The members' answers change: cp-b is no longer offered.
      current = _points(['cp-a', 'cp-c']);
      await tester.pump(kRestorePoll);
      await tester.pump();
      await tester.pump();
      final rows = tester.widgetList<HollowListRow>(find.byType(HollowListRow));
      expect(rows.any((r) => r.selected), isFalse);
      expect(_button(tester, 'Restore').onPressed, isNull,
          reason: 'Restore stays live for a point the person can no longer see');
      // Coming back does not bring the old pick with it.
      current = _points(['cp-a', 'cp-b']);
      await tester.pump(kRestorePoll);
      await tester.pump();
      expect(_button(tester, 'Restore').onPressed, isNull);
      await tester.pump(kRestorePoll);
    });

    testWidgets('a pick is dropped when the stage changes', (tester) async {
      var current = _points(['cp-a']);
      await _openChooser(tester, restores: () => current);
      await tester.tap(find.text(kRestoreDontKnow));
      await tester.pump();
      expect(_button(tester, 'Restore').onPressed, isNotNull);
      current = _points(['cp-a'], stage: dp.RestoreStage.onlyOne);
      await tester.pump(kRestorePoll);
      await tester.pump();
      await tester.pump();
      expect(_button(tester, 'Restore').onPressed, isNull);
      await tester.pump(kRestorePoll);
    });

    testWidgets('a phone gives every row and button a touch target',
        (tester) async {
      await _openChooser(tester,
          restores: () => _points(['cp-a', 'cp-b']),
          size: const Size(375, 812));
      final rows = tester.elementList(find.byType(HollowListRow)).toList();
      expect(rows, isNotEmpty);
      for (final r in rows) {
        expect(r.size!.height, greaterThanOrEqualTo(44));
      }
      final restore = find.ancestor(
          of: find.text('Restore'), matching: find.byType(HollowButton));
      expect(tester.getSize(restore).height, greaterThanOrEqualTo(44));
    });
  });

  group('restore chooser copy', () {
    testWidgets('a date from another year names the year', (tester) async {
      await _openChooser(tester, restores: () => _points(['cp-a']));
      // The fixture's point is from November 2025.
      expect(find.textContaining(', 2025, '), findsOneWidget);
    });

    testWidgets('a supporter with no name reads "a member" and an id end',
        (tester) async {
      const stranger = 'master_zed_00000000000000000099';
      await _openChooser(tester,
          restores: () => const dp.Restores(serversKnown: true, servers: [
                dp.RestoreChoices(
                    serverId: kServerId2,
                    stage: dp.RestoreStage.points,
                    points: [
                      dp.RestorePoint(
                          cp: 'cp-a', namedBy: [stranger], namedByNames: [null]),
                    ]),
              ]));
      expect(find.text('Named by ${memberFallback(shortPeerLabel(stranger))}'),
          findsOneWidget);
    });

    testWidgets('a supporter we hold no name for reads by its card name',
        (tester) async {
      const carded = 'master_zed_00000000000000000098';
      const blank = 'master_zed_00000000000000000097';
      await _openChooser(tester,
          restores: () => const dp.Restores(serversKnown: true, servers: [
                dp.RestoreChoices(
                    serverId: kServerId2,
                    stage: dp.RestoreStage.points,
                    points: [
                      dp.RestorePoint(
                          cp: 'cp-a',
                          namedBy: [kMira, carded],
                          namedByNames: ['Not Mira', 'Zed']),
                      dp.RestorePoint(
                          cp: 'cp-b', namedBy: [blank], namedByNames: ['']),
                    ]),
              ]));
      // Our name first, then the card's; an empty card reads as the id's end.
      expect(find.text('Named by Mira and Zed'), findsOneWidget);
      expect(find.text('Named by ${memberFallback(shortPeerLabel(blank))}'),
          findsOneWidget);
    });

    testWidgets('an empty list is "every server restored" only after one',
        (tester) async {
      var current = const dp.Restores(serversKnown: true, servers: []);
      await _openChooser(tester, restores: () => current);
      expect(find.text(kRestoreNothing), findsOneWidget);
      expect(find.text(restoreDone('Every server')), findsNothing);
      current = _points(['cp-a']);
      await tester.pump(kRestorePoll);
      await tester.pump();
      current = const dp.Restores(serversKnown: true, servers: []);
      await tester.pump(kRestorePoll);
      await tester.pump();
      expect(find.text(restoreDone('Every server')), findsOneWidget);
      await tester.pump(kRestorePoll);
    });

    testWidgets('a device with state never hears its servers are unknown',
        (tester) async {
      const unknown = dp.Restores(serversKnown: false, servers: []);
      await _openChooser(tester,
          restores: () => unknown,
          extra: [serverListProvider.overrideWith(_NoServers.new)]);
      expect(find.text(kRestoreUnknownServers), findsNothing);
      expect(find.text(kRestoreNothing), findsOneWidget);
    });
  });

  group('restore chooser offers', () {
    late ProviderContainer c;
    late _Gate gate;
    late List<bool> shown;
    late Completer<void> chain;
    late dp.Restores Function() answer;
    Completer<void>? read;
    var reads = 0;

    RestoreChooserOffers offers() => RestoreChooserOffers(
          c,
          alive: () => true,
          show: ({required fresh}) async => shown.add(fresh),
          fetch: () async {
            // An offer that skips a lock's wait reads again in a microtask loop
            // no test timeout can break; the cap ends it as a failed read.
            if (++reads > 20) throw StateError('read in a loop');
            if (read != null) await read!.future;
            return answer();
          },
          startChain: () => chain.future,
        );

    setUp(() {
      gate = _Gate(const RosterGate(kind: RosterGateKind.pending));
      c = ProviderContainer(overrides: [
        rosterGateProvider.overrideWith(() => gate),
        serverListProvider.overrideWith(_NoServers.new),
      ]);
      c.read(rosterGateProvider);
      shown = [];
      chain = Completer<void>()..complete();
      answer = () => _points(['cp-a']);
      read = null;
      reads = 0;
    });
    tearDown(() => c.dispose());

    test('waits for the roster lock, then for the app lock', () async {
      c.read(appLockedProvider.notifier).setLocked(true);
      final done = offers().afterRecovery(fresh: true);
      await pumpEventQueue();
      expect(shown, isEmpty);
      gate.set(const RosterGate());
      await pumpEventQueue();
      expect(shown, isEmpty, reason: 'the App Lock cover is still up');
      expect(reads, 0, reason: 'nothing is read under the cover');
      c.read(appLockedProvider.notifier).setLocked(false);
      await done;
      expect(shown, [true]);
      expect(reads, 1);
    });

    test('waits for the roster lock before it reads anything', () async {
      final done = offers().afterRecovery(fresh: true);
      await pumpEventQueue();
      expect(reads, 0, reason: 'the roster lock is up');
      expect(shown, isEmpty);
      gate.set(const RosterGate());
      await done;
      expect(shown, [true]);
      expect(reads, 1);
    });

    test('a lock raised during the read waits again before it shows',
        () async {
      gate.set(const RosterGate());
      read = Completer<void>();
      final done = offers().afterRecovery(fresh: false);
      await pumpEventQueue();
      c.read(appLockedProvider.notifier).setLocked(true);
      final held = read!;
      read = null;
      held.complete();
      await pumpEventQueue();
      expect(shown, isEmpty);
      c.read(appLockedProvider.notifier).setLocked(false);
      await done;
      expect(shown, [false]);
    });

    test('a roster lock raised during the read waits too', () async {
      gate.set(const RosterGate());
      read = Completer<void>();
      final done = offers().afterRecovery(fresh: false);
      await pumpEventQueue();
      gate.set(const RosterGate(kind: RosterGateKind.removed));
      final held = read!;
      read = null;
      held.complete();
      await pumpEventQueue();
      expect(shown, isEmpty);
      gate.set(const RosterGate());
      await done;
      expect(shown, [false]);
    });

    test('an offer queued behind the start never reopens a closed chooser',
        () async {
      gate.set(const RosterGate());
      chain = Completer<void>();
      final o = offers();
      final queued = o.afterRecovery(fresh: false);
      await pumpEventQueue();
      expect(shown, isEmpty, reason: 'it waits for the start chain');
      await o.atStart(countedAtStart: true);
      expect(shown, [false]);
      chain.complete();
      await queued;
      expect(shown, [false]);
      await o.atStart(countedAtStart: true);
      expect(shown, [false], reason: 'closed once this run');
    });

    test('a start never offers on a device the roster does not count',
        () async {
      await offers().atStart(countedAtStart: true);
      expect(shown, isEmpty);
    });

    test('a device let in during the start is not offered the chooser',
        () async {
      final counted = c.read(rosterGateProvider).kind == RosterGateKind.none;
      // Joining with the phrase at the roster lock, while the start waits.
      gate.set(const RosterGate());
      await offers().atStart(countedAtStart: counted);
      expect(shown, isEmpty, reason: 'joining is not a recovery');
    });

    test('only the roster-lock path says the servers are unknown', () async {
      gate.set(const RosterGate());
      answer = () => const dp.Restores(serversKnown: false, servers: []);
      await offers().afterRecovery(fresh: false);
      expect(shown, isEmpty);
      await offers().afterRecovery(fresh: true);
      expect(shown, [true]);
    });

    test('the ask records which path asked', () {
      askForRestoreChooser(c, fresh: true);
      askForRestoreChooser(c, fresh: false);
      final ask = c.read(restoreChooserAskProvider)!;
      expect((ask.seq, ask.fresh), (2, false));
    });
  });

  group('lost device review', () {
    testWidgets('Keep all asks before it drops a selection', (tester) async {
      await _pumpPage(tester,
          overrides: deviceProofOverrides(reviews: fixtureReviews));
      await tester.tap(find.text('Select all'));
      await tester.pump();
      await tester.tap(find.text('Keep all'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_api.answers, isEmpty,
          reason: 'Keep all with 7 changes ticked answered at once');
      expect(find.text(keepAllMessage(total: 7, picked: 7)), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_api.answers, isEmpty);
      await tester.tap(find.text('Keep all'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Keep all').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_api.answers, [
        [<String>[], <String>[]],
      ]);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a deleted label or channel never reads "a"', (tester) async {
      await _pumpPage(tester,
          overrides: deviceProofOverrides(
              reviews: dp.RefoldReviews(reviews: [
            _review(const [
              dp.RefoldItem(
                  key: 'k-label',
                  group: dp.RefoldGroup.things,
                  kind: dp.RefoldItemKind.labelDeleted,
                  labelId: 'label_gone',
                  opens: false),
              dp.RefoldItem(
                  key: 'k-chan',
                  group: dp.RefoldGroup.things,
                  kind: dp.RefoldItemKind.channelDeleted,
                  channelId: 'channel_gone',
                  opens: false),
            ]),
          ], moreReports: 0)));
      expect(find.textContaining('The a label'), findsNothing);
      expect(find.textContaining('A label was deleted.'), findsOneWidget);
      expect(find.textContaining('A channel was deleted.'), findsOneWidget);
    });

    test('a deleted item reads by the name its op held', () {
      final names = RefoldNames(
        server: 'S',
        member: 'Mira',
        person: (_) => null,
        unnamedPerson: memberFallback,
        channel: (_) => null,
        label: (_) => null,
        role: (r) => r,
      );
      String line(dp.RefoldItemKind k) => refoldItemText(
              dp.RefoldItem(
                  key: 'k',
                  group: dp.RefoldGroup.things,
                  kind: k,
                  channelId: 'c',
                  labelId: 'l',
                  target: 't',
                  opens: false,
                  channelName: 'old-news',
                  labelName: 'Supporters',
                  targetName: 'Ilse'),
              names)
          .line;
      expect(line(dp.RefoldItemKind.labelDeleted),
          startsWith('The Supporters label was deleted.'));
      expect(line(dp.RefoldItemKind.channelDeleted),
          startsWith('#old-news was deleted.'));
      expect(line(dp.RefoldItemKind.muted),
          'Ilse was muted. Undoing lifts the mute.');
      // Nothing known at all: our own fallbacks, capitalized at a start.
      final bare = RefoldNames(
        server: 'S',
        member: 'Mira',
        person: (_) => null,
        unnamedPerson: memberFallback,
        channel: (_) => null,
        label: (_) => null,
        role: (r) => r,
      );
      expect(
          refoldItemText(
                  const dp.RefoldItem(
                      key: 'k',
                      group: dp.RefoldGroup.mutes,
                      kind: dp.RefoldItemKind.muted,
                      target: '12D3…abc',
                      opens: false),
                  bare)
              .line,
          'A member (12D3…abc) was muted. Undoing lifts the mute.');
    });

    testWidgets(
        'Apply saves the answer, takes no second one and names what stays',
        (tester) async {
      _api.changedSince = {'k-ban', kChannelId1};
      addTearDown(() => _api.changedSince = {});
      await _pumpPage(tester, overrides: [
        ...deviceProofOverrides(reviews: fixtureReviews),
      ]);
      await _toggle(tester, 'refold-item-k-ban');
      await _toggle(tester, 'refold-item-k-mute');
      await _toggle(tester, 'put-back-$kChannelId1');
      await tester.tap(find.text('Apply selected'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_api.answers.single, [
        ['k-ban', 'k-mute'],
        [kChannelId1]
      ]);
      // The one that applied names nothing.
      expect(find.textContaining('Ilse was muted. Someone changed'), findsNothing);
      // Saved, in progress: never "done".
      expect(refoldApplied('Test Server'),
          'Your answer is saved. Test Server applies it next.');
      expect(find.text(refoldApplied('Test Server')), findsWidgets);
      expect(find.text(refoldChangedSince('Tomas was banned')), findsOneWidget);
      expect(find.text(putBackChangedSince('#general')), findsOneWidget);
      // No second answer from this section.
      expect(find.text('Apply selected'), findsNothing);
      expect(find.text('Keep all'), findsNothing);
      expect(find.byKey(const ValueKey('refold-item-k-mute')), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a failed first read keeps the page and its Retry',
        (tester) async {
      await _pumpPage(tester, overrides: [
        ...deviceProofOverrides(),
        refoldReviewsProvider(kServerId1)
            .overrideWith((_) async => throw Exception('node down')),
      ]);
      expect(find.byType(SettingsLoadFailed), findsOneWidget);
    });

    test('the rail keeps Lost devices for the owner after a failed read', () {
      const failed =
          AsyncValue<dp.RefoldReviews>.error('down', StackTrace.empty);
      expect(showsLostDevices(failed, role: 'owner'), isTrue);
      expect(showsLostDevices(failed, role: 'admin'), isFalse);
      expect(
          showsLostDevices(
              const AsyncValue.data(
                  dp.RefoldReviews(reviews: [], moreReports: 0)),
              role: 'owner'),
          isFalse);
      expect(showsLostDevices(AsyncValue.data(fixtureReviews), role: 'admin'),
          isTrue);
    });
  });

  group('banners', () {
    testWidgets('Leave is a cautionary outline', (tester) async {
      await _pumpBanner(tester);
      final leave = _button(tester, 'Leave Test Server');
      expect(leave.variant, HollowButtonVariant.outline);
      expect(leave.danger, isTrue);
    });

    testWidgets('the owner notice counts members by id, not by name',
        (tester) async {
      crdt_api.MemberFfi sam(String id) => crdt_api.MemberFfi(
          peerId: id,
          displayName: 'Sam',
          role: 'member',
          nickname: 'Sam',
          twitchUsername: '',
          labels: const []);
      await _pumpBanner(tester,
          recovery: const dp.ServerRecovery(steppedBack: false),
          reviews: dp.RefoldReviews(reviews: [
            _review(const [], member: kIlse, device: 'device_a_000000000000001'),
            _review(const [], member: kIlse, device: 'device_b_000000000000001'),
            _review(const [], member: kOskar),
          ], moreReports: 0),
          extra: [
            serverMembersProvider(kServerId1)
                .overrideWith((_) async => [sam(kIlse), sam(kOskar)]),
          ]);
      expect(find.text(refoldNotice(['Sam', 'Sam'], 'Test Server')),
          findsOneWidget);
    });

    testWidgets('the real channel pane shows the strip under its header',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final channel = testChannels[kChannelId1]!;
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          ...deviceProofOverrides(
              recovery:
                  const dp.ServerRecovery(steppedBack: true, removedBy: kTomas)),
          selectedServerProvider.overrideWith((_) => kServerId1),
          selectedChannelProvider.overrideWith((_) => kChannelId1),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
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
      expect(find.text(shellBanner('Tomas', 'Test Server')), findsOneWidget);
      expect(find.text('Leave Test Server'), findsOneWidget);
    });

    for (final phone in [false, true]) {
      testWidgets(
          'a member removed meanwhile gets the reason, not a composer'
          '${phone ? ' (phone)' : ''}', (tester) async {
        await _pumpChat(tester,
            phone: phone,
            recovery: const dp.ServerRecovery(steppedBack: true));
        expect(find.byType(ChatComposerRow), findsOneWidget,
            reason: 'a restoring server alone leaves the composer open');
        await _pumpChat(tester,
            phone: phone,
            recovery:
                const dp.ServerRecovery(steppedBack: true, removedBy: kTomas));
        expect(find.byType(ChatComposerRow), findsNothing);
        expect(find.text(kRemovedComposer), findsOneWidget);
      });
    }
  });

  group('stale state', () {
    test('restore choices are read again when the app comes back', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final sub = c.listen(restoreChoicesProvider, (_, _) {});
      addTearDown(sub.close);
      await c.read(restoreChoicesProvider.future);
      expect(_api.restoreReads, 1);
      c.read(appLifecycleProvider.notifier).state = AppLifecycleState.paused;
      await pumpEventQueue();
      expect(_api.restoreReads, 1);
      c.read(appLifecycleProvider.notifier).state = AppLifecycleState.resumed;
      await c.read(restoreChoicesProvider.future);
      expect(_api.restoreReads, 2);
    });

  });

  group('wiring', () {
    String src(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');

    test('the shell offers through the gated offers, behind its start', () {
      final shell = src('lib/src/ui/shell/hollow_shell.dart');
      final start = shell.indexOf('Future<void> _offerAfterStart(');
      final body = shell.substring(start, shell.indexOf('\n  }\n', start));
      expect(body.indexOf('_startOffers = done.future;'),
          allOf(greaterThan(-1), lessThan(body.indexOf('await _askTermsAgreement();'))),
          reason: 'an after-recovery offer must wait for the whole start chain');
      expect(body, contains('await _restoreOffers.atStart(countedAtStart: counted);'));
      expect(
          body.indexOf(
              'final counted = ref.read(rosterGateProvider).kind == RosterGateKind.none;'),
          allOf(greaterThan(-1), lessThan(body.indexOf('await _askTermsAgreement();'))),
          reason: 'the gate is read before the offers that wait for the roster');
      expect(shell, contains('startChain: () => _startOffers'));
      expect(shell, contains('_restoreOffers.afterRecovery(fresh: ask.fresh)'));
      expect(shell.split('showRestoreChooser(').length, 2,
          reason: 'the shell opens the chooser only through RestoreChooserOffers');
    });

    test('ServerUpdated re-reads the restore and review state', () {
      final events = src('lib/src/core/providers/event_provider.dart');
      final start = events.indexOf('void _refreshServerState(');
      expect(start, greaterThan(-1));
      final body = events.substring(start, events.indexOf('\n  }\n', start));
      for (final p in [
        'serverRecoveryProvider(serverId)',
        'refoldReviewsProvider(serverId)',
        'restoreChoicesProvider',
      ]) {
        expect(body, contains('ref.invalidate($p);'), reason: p);
      }
    });

    test('only the roster lock asks as a fresh recovery', () {
      expect(src('lib/src/ui/shell/roster_lock.dart'),
          contains('askForRestoreChooser(container, fresh: true);'));
      expect(src('lib/src/ui/settings/security_section.dart'),
          contains('askForRestoreChooser(container, fresh: false);'));
    });
  });
}

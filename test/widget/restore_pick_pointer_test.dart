/// The way back to the restore chooser once it was closed (F5): a Home row per
/// server waiting for the person's pick (phone and Dock), and Classic's strip
/// under the status banners, since Classic has no Home.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';
import 'package:hollow/src/ui/shell/restore_pick_banner.dart';

import '../helpers/device_proof_fixtures.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

class _Setup extends HomeSetupNotifier {
  @override
  HomeSetupState build() =>
      const HomeSetupState(loaded: true, hidden: true, phraseSaved: true);
}

Future<void> _pump(WidgetTester tester, Widget child, dp.Restores restores,
    {Size size = const Size(1000, 1200)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      homeSetupProvider.overrideWith(_Setup.new),
      ...deviceProofOverrides(restores: restores),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

const _home = SingleChildScrollView(child: HomeAttention());
const _classic = Column(children: [RestorePickBanner(), Spacer()]);

Finder _pickRow(String serverId) =>
    find.byKey(ValueKey('restore-pick:$serverId'));

/// Whether [first]'s server sits above [second]'s in the open chooser.
bool _listedFirst(WidgetTester tester, String first, String second) =>
    tester.getTopLeft(find.byKey(ValueKey('restore-points-$first'))).dy <
    tester.getTopLeft(find.byKey(ValueKey('restore-points-$second'))).dy;

Future<void> _tapChoose(WidgetTester tester, Finder within) async {
  await tester.tap(
      find.descendant(of: within, matching: find.text(kRestorePickAction)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  group('Home', () {
    for (final (stage, server, id) in [
      (dp.RestoreStage.pick, 'Test Server', kServerId1),
      (dp.RestoreStage.points, 'Dev Hangout', kServerId2),
      (dp.RestoreStage.onlyOne, 'Test Server', kServerId1),
    ]) {
      testWidgets('a server at the ${stage.name} stage waits on Home',
          (tester) async {
        await _pump(tester, _home, fixtureRestores([stage]));
        expect(_pickRow(id), findsOneWidget);
        expect(find.text(restorePickTitle(server)), findsOneWidget);
        expect(find.text(kRestorePickBody), findsOneWidget);
        expect(find.text(kRestorePickAction), findsOneWidget);
      });
    }

    for (final stage in [
      dp.RestoreStage.done,
      dp.RestoreStage.checking,
      dp.RestoreStage.waiting,
      dp.RestoreStage.nobodyReachable,
    ]) {
      testWidgets('a server at the ${stage.name} stage has no pick row',
          (tester) async {
        await _pump(tester, _home, fixtureRestores([stage]));
        expect(_pickRow(kServerId1), findsNothing);
        expect(find.text(kRestorePickBody), findsNothing);
      });
    }

    testWidgets('a server waiting for a member keeps only its own row',
        (tester) async {
      await _pump(
          tester, _home, fixtureRestores([dp.RestoreStage.waitingForMember]));
      expect(find.text(restoreWaitTitle('Test Server')), findsOneWidget);
      expect(_pickRow(kServerId1), findsNothing);
      expect(find.text(kRestorePickAction), findsNothing);
    });

    testWidgets('one row per waiting server, and Choose opens on that server',
        (tester) async {
      await _pump(tester, _home,
          fixtureRestores([dp.RestoreStage.onlyOne, dp.RestoreStage.points]));
      expect(_pickRow(kServerId1), findsOneWidget);
      expect(_pickRow(kServerId2), findsOneWidget);

      await _tapChoose(tester, _pickRow(kServerId2));
      expect(find.text(kRestoreTitle), findsOneWidget);
      expect(_listedFirst(tester, kServerId2, kServerId1), isTrue,
          reason: 'the chooser opens on the server whose row was tapped');
    });

    testWidgets('the phone lists the server on the Chats tab', (tester) async {
      await pumpHollowMobile(tester, extraOverrides: [
        homeSetupProvider.overrideWith(_Setup.new),
        ...deviceProofOverrides(
            restores: fixtureRestores(
                [dp.RestoreStage.onlyOne, dp.RestoreStage.points])),
      ]);
      expect(find.text(restorePickTitle('Dev Hangout')), findsOneWidget);
      await tester.scrollUntilVisible(
          find.descendant(
              of: _pickRow(kServerId2),
              matching: find.text(kRestorePickAction)),
          200,
          scrollable: find.byType(Scrollable).first);
      await _tapChoose(tester, _pickRow(kServerId2));
      expect(find.text(kRestoreTitle), findsOneWidget);
      expect(_listedFirst(tester, kServerId2, kServerId1), isTrue);
    });
  });

  group('Classic', () {
    testWidgets('one waiting server is named, and Choose opens on it',
        (tester) async {
      await _pump(
          tester, _classic, fixtureRestores([dp.RestoreStage.points]),
          size: const Size(1280, 800));
      expect(find.text(restorePickTitle('Dev Hangout')), findsOneWidget);
      expect(find.text(kRestorePickBody), findsOneWidget);
      await _tapChoose(tester, find.byType(RestorePickBanner));
      expect(find.text(kRestoreTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('restore-points-$kServerId2')),
          findsOneWidget);
    });

    testWidgets('several waiting servers are counted, the first opens first',
        (tester) async {
      await _pump(tester, _classic,
          fixtureRestores([dp.RestoreStage.onlyOne, dp.RestoreStage.points]),
          size: const Size(1280, 800));
      expect(find.text(restorePickManyTitle(2)), findsOneWidget);
      await _tapChoose(tester, find.byType(RestorePickBanner));
      expect(_listedFirst(tester, kServerId1, kServerId2), isTrue);
    });

    for (final stage in [
      dp.RestoreStage.done,
      dp.RestoreStage.waitingForMember,
      dp.RestoreStage.checking,
    ]) {
      testWidgets('nothing shows at the ${stage.name} stage', (tester) async {
        await _pump(tester, _classic, fixtureRestores([stage]),
            size: const Size(1280, 800));
        expect(find.byKey(const ValueKey('restore-pick-banner')), findsNothing);
      });
    }

    testWidgets('a narrow window puts Choose under the words', (tester) async {
      await _pump(tester, _classic, fixtureRestores([dp.RestoreStage.pick]),
          size: const Size(420, 600));
      expect(tester.takeException(), isNull);
      expect(
          tester.getTopLeft(find.text(kRestorePickAction)).dy,
          greaterThan(tester.getTopLeft(find.text(kRestorePickBody)).dy));
    });

    test('only the Classic layout carries the strip', () {
      final shell =
          File('lib/src/ui/shell/hollow_shell.dart').readAsStringSync();
      final classic = shell.indexOf('Widget _buildClassicLayout(');
      final dock = shell.indexOf('Widget _buildDockLayout(');
      expect(classic, greaterThan(-1));
      expect(dock, greaterThan(-1));
      final classicBody = shell.substring(
          classic, shell.indexOf('\n  }\n', classic));
      final dockBody = shell.substring(dock, shell.indexOf('\n  }\n', dock));
      expect(classicBody, contains('const RestorePickBanner()'));
      expect(dockBody, isNot(contains('RestorePickBanner')));
      expect(shell.split('RestorePickBanner()').length, 2);
    });
  });
}

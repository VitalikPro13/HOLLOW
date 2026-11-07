/// The device-proof screens at 320 px, text scale 1 and 2, with a long server
/// name: the chooser in every stage, every banner, and the review page. A
/// RenderFlex overflow fails the test on its own.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/server_recovery_notices.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/restore_chooser.dart';
import 'package:hollow/src/ui/server_settings/pages/lost_devices_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/device_proof_fixtures.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

const _longName = 'The Northern Lights Photography Collective';

const _servers = {
  kServerId1: ServerInfo(serverId: kServerId1, name: _longName),
  kServerId2: ServerInfo(serverId: kServerId2, name: '$_longName 2'),
};

Future<void> _pump(WidgetTester tester, Widget home,
    {required double scale,
    required List<Override> overrides,
    Size size = const Size(320, 568)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: overrides),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: w!),
      home: home,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Finder _leave() => find.ancestor(
    of: find.textContaining('Leave '), matching: find.byType(HollowButton));

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  final stages = {
    'pick': [dp.RestoreStage.pick],
    'points': [dp.RestoreStage.points],
    'only one, waiting': [dp.RestoreStage.onlyOne, dp.RestoreStage.waiting],
    'checking, nobody, done': [
      dp.RestoreStage.checking,
      dp.RestoreStage.nobodyReachable,
      dp.RestoreStage.done,
    ],
  };

  for (final scale in [1.0, 2.0]) {
    for (final e in stages.entries) {
      testWidgets('chooser ${e.key} at 320, text scale $scale', (tester) async {
        await _pump(
          tester,
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () => showRestoreChooser(context),
                  child: const Text('open')),
            ),
          ),
          scale: scale,
          overrides: deviceProofOverrides(
              restores: fixtureRestores(e.value), servers: _servers),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(RestoreChooserDialog), findsOneWidget);
      });
    }

    for (final touch in [false, true]) {
      testWidgets('banners at 320, text scale $scale, touch $touch',
          (tester) async {
        await _pump(
          tester,
          Scaffold(
            body: SingleChildScrollView(
                child: ServerRecoveryNotices(serverId: kServerId1, touch: touch)),
          ),
          scale: scale,
          overrides: deviceProofOverrides(
              reviews: fixtureReviews,
              recovery:
                  const dp.ServerRecovery(steppedBack: true, removedBy: kTomas),
              servers: _servers),
        );
        // Stacked under the words, the action takes the strip's width.
        expect(tester.getSize(_leave()).width,
            closeTo(320 - 2 * HollowSpacing.lg, 0.5));
      });
    }

    testWidgets('review page at 320, text scale $scale', (tester) async {
      await _pump(
        tester,
        const Scaffold(
          body: SettingsDensity(
            touch: true,
            child: SingleChildScrollView(
                child: LostDevicesPage(serverId: kServerId1)),
          ),
        ),
        scale: scale,
        overrides:
            deviceProofOverrides(reviews: fixtureReviews, servers: _servers),
      );
      expect(find.text('Apply selected'), findsOneWidget);
    });
  }

  testWidgets('a wide strip keeps the action beside the words', (tester) async {
    await _pump(
      tester,
      const Scaffold(
          body: SingleChildScrollView(
              child: ServerRecoveryNotices(serverId: kServerId1))),
      scale: 1.0,
      size: const Size(1000, 400),
      overrides: deviceProofOverrides(
          recovery:
              const dp.ServerRecovery(steppedBack: true, removedBy: kTomas)),
    );
    expect(tester.getSize(_leave()).width, lessThan(400));
  });

  testWidgets('large text stacks the action sooner', (tester) async {
    await _pump(
      tester,
      const Scaffold(
          body: SingleChildScrollView(
              child: ServerRecoveryNotices(serverId: kServerId1))),
      scale: 2.0,
      size: const Size(700, 900),
      overrides: deviceProofOverrides(
          recovery:
              const dp.ServerRecovery(steppedBack: true, removedBy: kTomas)),
    );
    expect(tester.getSize(_leave()).width,
        closeTo(700 - 2 * HollowSpacing.lg, 0.5));
  });
}

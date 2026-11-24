import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/settings/pages/devices_page.dart';

import '../helpers/test_app.dart';

const _asker = '12D3KooWAskerAskerAskerAskerAskerAskerAskerAsker';

/// When a recovery cut the asker off: Nov 20 2026.
const _cutAt = 1_795_000_000_000;

roster_api.RosterStatus _status({String? cutOff}) => roster_api.RosterStatus(
      member: true,
      protected: true,
      backupWait: false,
      devices: [
        const roster_api.RosterDevice(devicePeerId: 'me', state: 'member', thisDevice: true, added: []),
        roster_api.RosterDevice(
          devicePeerId: _asker,
          state: 'pending',
          thisDevice: false,
          added: const [],
          firstSeenMs: _cutAt + 60000,
          cutOffAtMs: cutOff == null ? null : _cutAt,
          cutOff: cutOff,
        ),
      ],
    );

class _RosterApi implements RustLibApi {
  int approvals = 0;
  int refusals = 0;

  @override
  Future<void> crateApiRosterApproveDevice({required String devicePeerId}) async => approvals++;

  @override
  Future<void> crateApiRosterRefuseDevice({required String devicePeerId}) async => refusals++;

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

/// HOL-SEC-229 follow-up: the recovery cut this device off because someone else may
/// hold it, so letting it back in takes a second, explicit step. Every other waiting
/// device keeps its one-tap Approve, and Refuse stays one tap for all.
void main() {
  final api = _RosterApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.approvals = 0;
    api.refusals = 0;
  });

  for (final size in const [Size(900, 1400), Size(375, 1400)]) {
    final where = size.width < 600 ? 'phone' : 'desktop';

    Future<void> pumpDevices(WidgetTester tester, {String? cutOff}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          myDevicesProvider.overrideWithValue(const [
            MyDevice(peerId: 'me', isThisDevice: true, online: true, label: 'Desk'),
          ]),
          rosterStatusProvider.overrideWith((ref) async => _status(cutOff: cutOff)),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: const Scaffold(body: SingleChildScrollView(child: DevicesSettingsPage())),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Waiting'), findsOneWidget);
    }

    for (final cutOff in ['maybe', 'ours']) {
      testWidgets('approving a device a recovery cut off ($cutOff) asks to confirm first ($where)', (tester) async {
        await pumpDevices(tester, cutOff: cutOff);

        final asks = ProviderScope.containerOf(tester.element(find.byType(DevicesSettingsPage)))
            .read(pendingDeviceAsksProvider.notifier);
        asks.add(_asker);

        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        expect(find.text('Let this device back in?'), findsOneWidget);
        expect(find.textContaining('whoever holds it gets your messages again'), findsOneWidget);
        expect(
          find.ancestor(
            of: find.text('Approve').last,
            matching: find.byWidgetPredicate(
                (w) => w is HollowButton && w.variant == HollowButtonVariant.danger),
          ),
          findsOneWidget,
        );
        expect(api.approvals, 0);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Let this device back in?'), findsNothing);
        expect(find.text('Waiting'), findsOneWidget);
        expect(api.approvals, 0);
        expect(api.refusals, 0);
        expect(asks.state, [_asker]);

        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        // The dialog's own Approve is the last one in the tree.
        await tester.tap(find.text('Approve').last);
        await tester.pumpAndSettle();
        expect(find.text('Let this device back in?'), findsNothing);
        expect(api.approvals, 1);
        expect(asks.state, isEmpty);
      });

      testWidgets('refusing a device a recovery cut off ($cutOff) stays one tap ($where)', (tester) async {
        await pumpDevices(tester, cutOff: cutOff);
        await tester.tap(find.text('Refuse'));
        await tester.pumpAndSettle();
        expect(find.text('Let this device back in?'), findsNothing);
        expect(api.refusals, 1);
        expect(api.approvals, 0);
      });
    }

    testWidgets('a device restored from a backup still approves in one step ($where)', (tester) async {
      await pumpDevices(tester);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      expect(find.text('Let this device back in?'), findsNothing);
      expect(api.approvals, 1);
    });
  }
}

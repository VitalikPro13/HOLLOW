import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/shell/roster_lock.dart';

import '../helpers/test_app.dart';

const _asker = '12D3KooWAskerAskerAskerAskerAskerAskerAskerAsker';

/// When a recovery cut the asker off, in [_status]: Nov 20 2026.
const _cutAt = 1_795_000_000_000;

roster_api.RosterStatus _status(String askerState, {bool backupWait = true, bool member = true, String? cutOff}) =>
    roster_api.RosterStatus(
      member: member,
      protected: true,
      backupWait: backupWait,
      devices: [
        if (member) const roster_api.RosterDevice(devicePeerId: 'me', state: 'member', thisDevice: true, added: []),
        roster_api.RosterDevice(
          devicePeerId: _asker,
          state: askerState,
          thisDevice: false,
          added: const [],
          firstSeenMs: cutOff == null ? null : _cutAt + 60000,
          cutOffAtMs: cutOff == null ? null : _cutAt,
          cutOff: cutOff,
        ),
      ],
    );

/// Our roster as Rust holds it; the tests move the asker between states.
class _RosterApi implements RustLibApi {
  String askerState = 'pending';
  bool member = true;
  bool backupWait = true;
  String? cutOff;
  bool statusFails = false;
  int refusals = 0;

  @override
  Future<roster_api.RosterStatus> crateApiRosterRosterStatus() async {
    if (statusFails) throw Exception('the store is busy');
    return _status(askerState, member: member, backupWait: backupWait, cutOff: cutOff);
  }

  @override
  Future<void> crateApiRosterRefuseDevice({required String devicePeerId}) async => refusals++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A join ask is a question about a device that WAITS. One settled meanwhile (on
/// another device, or by the phrase typed on the asker) must never be put to the
/// person: its Refuse would remove a device that is a member by then.
void main() {
  final api = _RosterApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.askerState = 'pending';
    api.member = true;
    api.backupWait = true;
    api.cutOff = null;
    api.statusFails = false;
    api.refusals = 0;
  });

  late WidgetRef hostRef;
  late BuildContext host;

  Future<ProviderContainer> pumpHost(WidgetTester tester, {List<Override> extra = const []}) async {
    final container = ProviderContainer(overrides: hollowTestOverrides(extra: extra));
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Consumer(builder: (context, ref, _) {
          host = context;
          hostRef = ref;
          return const SizedBox.expand();
        })),
      ),
    ));
    return container;
  }

  testWidgets('an ask settled before it shows is dropped unseen', (tester) async {
    // The open dialog's own watch is held at "waiting", so only the check made
    // before showing can drop this ask.
    final container = await pumpHost(tester, extra: [
      rosterStatusProvider.overrideWith((ref) async => _status('pending')),
    ]);
    container.read(pendingDeviceAsksProvider.notifier).add(_asker);
    api.askerState = 'member';

    final shown = showPendingDeviceDialog(host, hostRef, _asker);
    await tester.pumpAndSettle();

    expect(find.text('A device wants to join'), findsNothing);
    await shown;
    expect(container.read(pendingDeviceAsksProvider), isEmpty);
  });

  testWidgets('an open ask closes once the roster settles it elsewhere', (tester) async {
    final container = await pumpHost(tester);
    container.read(pendingDeviceAsksProvider.notifier).add(_asker);

    final shown = showPendingDeviceDialog(host, hostRef, _asker);
    await tester.pumpAndSettle();
    expect(find.text('A device wants to join'), findsOneWidget);

    api.askerState = 'member';
    container.invalidate(rosterStatusProvider);
    await tester.pumpAndSettle();

    expect(find.text('A device wants to join'), findsNothing);
    await shown;
    expect(api.refusals, 0);
    expect(container.read(pendingDeviceAsksProvider), isEmpty);
  });

  // The ask promises seven days only while waiting can still let a device in.
  for (final waits in [true, false]) {
    testWidgets('the ask ${waits ? 'mentions' : 'does not mention'} the seven days', (tester) async {
      await pumpHost(tester, extra: [
        rosterStatusProvider.overrideWith((ref) async => _status('pending', backupWait: waits)),
      ]);
      final shown = showPendingDeviceDialog(host, hostRef, _asker);
      await tester.pumpAndSettle();
      expect(find.textContaining('it joins in seven days'), waits ? findsOneWidget : findsNothing);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      await shown;
    });
  }

  testWidgets('a waiting device is asked about and can be refused', (tester) async {
    await pumpHost(tester);
    final shown = showPendingDeviceDialog(host, hostRef, _asker);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Refuse'));
    await tester.pumpAndSettle();
    await shown;

    expect(api.refusals, 1);
    expect(find.text('A device wants to join'), findsNothing);
  });

  // A device the roster does not count (a phrase recovery left it out) vouches for
  // nothing, so it is never put the question, and an open one closes once it is out.
  testWidgets('a device the phrase left out is never asked to approve a join', (tester) async {
    final container = await pumpHost(tester, extra: [
      rosterStatusProvider.overrideWith((ref) async => _status('pending')),
    ]);
    container.read(pendingDeviceAsksProvider.notifier).add(_asker);
    api.member = false;

    final shown = showPendingDeviceDialog(host, hostRef, _asker);
    await tester.pumpAndSettle();

    expect(find.text('A device wants to join'), findsNothing);
    await shown;
    expect(api.refusals, 0);
    expect(container.read(pendingDeviceAsksProvider), isEmpty);
  });

  testWidgets('an open ask closes once this device is left out', (tester) async {
    final container = await pumpHost(tester);
    final shown = showPendingDeviceDialog(host, hostRef, _asker);
    await tester.pumpAndSettle();
    expect(find.text('A device wants to join'), findsOneWidget);

    api.member = false;
    container.invalidate(rosterStatusProvider);
    await tester.pumpAndSettle();

    expect(find.text('A device wants to join'), findsNothing);
    await shown;
    expect(api.refusals, 0);
  });

  // HOL-SEC-229: a device a recovery cut off is the one the person said someone else
  // may hold. No pop-up ever calls it a restored backup or offers to approve it.
  for (final cutOff in ['ours', 'maybe']) {
    testWidgets('a device a recovery cut off ($cutOff) is never offered as restored from a backup', (tester) async {
      api.cutOff = cutOff;
      api.backupWait = false;
      final container = await pumpHost(tester, extra: [
        rosterStatusProvider.overrideWith((ref) async => _status('pending', backupWait: false, cutOff: cutOff)),
      ]);
      container.read(pendingDeviceAsksProvider.notifier).add(_asker);

      final shown = showPendingDeviceDialog(host, hostRef, _asker);
      await tester.pumpAndSettle();

      expect(find.byType(HollowDialog), findsNothing, reason: 'it cannot join by waiting: nothing to warn of');
      expect(find.textContaining('restored from a backup'), findsNothing);
      await shown;
      expect(container.read(pendingDeviceAsksProvider), isEmpty);
    });

    testWidgets('a cut-off device ($cutOff) that can join by waiting is only warned of, never offered approval',
        (tester) async {
      api.cutOff = cutOff;
      await pumpHost(tester, extra: [
        rosterStatusProvider.overrideWith((ref) async => _status('pending', cutOff: cutOff)),
      ]);
      final shown = showPendingDeviceDialog(host, hostRef, _asker);
      await tester.pumpAndSettle();

      expect(find.byType(HollowDialog), findsOneWidget);
      expect(find.text(cutOff == 'ours' ? 'A device you cut off asks to join' : 'A device asks to join'), findsOneWidget);
      expect(find.textContaining('Your recovery phrase cut'), findsOneWidget);
      expect(find.textContaining('restored from a backup'), findsNothing);
      expect(find.text('Approve'), findsNothing);
      await tester.tap(find.text('Refuse'));
      await tester.pumpAndSettle();
      await shown;
      expect(api.refusals, 1);
    });
  }

  testWidgets('an open approval ask closes once the device turns out cut off', (tester) async {
    final container = await pumpHost(tester);
    final shown = showPendingDeviceDialog(host, hostRef, _asker);
    await tester.pumpAndSettle();
    expect(find.text('Approve'), findsOneWidget);

    api.cutOff = 'ours';
    container.invalidate(rosterStatusProvider);
    await tester.pumpAndSettle();

    expect(find.text('Approve'), findsNothing);
    await shown;
  });

  // HOL-SEC-229 review: a status that cannot be read says nothing about whether a
  // recovery cut the device off, so it never opens the pop-up that offers Approve.
  testWidgets('an unreadable roster never offers Approve for a device that may be cut off', (tester) async {
    api.cutOff = 'ours';
    api.statusFails = true;
    final container = await pumpHost(tester);
    container.read(pendingDeviceAsksProvider.notifier).add(_asker);

    final shown = showPendingDeviceDialog(host, hostRef, _asker);
    await tester.pumpAndSettle();

    expect(find.byType(HollowDialog), findsNothing);
    expect(find.text('Approve'), findsNothing);
    expect(await shown, isFalse, reason: 'the caller must stop asking until the roster reads again');
    expect(container.read(pendingDeviceAsksProvider), [_asker], reason: 'the ask stays queued for the next read');
  });
}

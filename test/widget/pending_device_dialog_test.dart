import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/roster_lock.dart';

import '../helpers/test_app.dart';

const _asker = '12D3KooWAskerAskerAskerAskerAskerAskerAskerAsker';

roster_api.RosterStatus _status(String askerState, {bool backupWait = true}) => roster_api.RosterStatus(
      member: true,
      protected: true,
      backupWait: backupWait,
      devices: [
        const roster_api.RosterDevice(devicePeerId: 'me', state: 'member', thisDevice: true),
        roster_api.RosterDevice(devicePeerId: _asker, state: askerState, thisDevice: false),
      ],
    );

/// Our roster as Rust holds it; the tests move the asker between states.
class _RosterApi implements RustLibApi {
  String askerState = 'pending';
  int refusals = 0;

  @override
  Future<roster_api.RosterStatus> crateApiRosterRosterStatus() async => _status(askerState);

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
}

/// Home's conversation list: Saved messages pinned first, a friend with no
/// messages showing no time (it read "Jan 1, 2000"), and the recovery phrase
/// reminder surviving a hidden checklist.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/rust/api/verification.dart' as verification_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/conversation_row.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';

import '../helpers/test_app.dart';

class _Alerts extends SecurityAlertsNotifier {
  final List<verification_api.SecurityAlertFfi> seed;
  _Alerts(this.seed);
  @override
  List<verification_api.SecurityAlertFfi> build() => seed;
}

class _Kinds extends DeviceKindNotifier {
  @override
  Map<String, String> build() => const {_desk: 'desktop', _added: 'phone'};
}

const _desk = '12D3KooWDeskDeskDeskDeskDeskDeskDeskDeskDesk';
const _added = '12D3KooWAddedAddedAddedAddedAddedAddedAdded';

class _Setup extends HomeSetupNotifier {
  final HomeSetupState seed;
  _Setup(this.seed);
  @override
  HomeSetupState build() => seed;
}

Future<void> _pump(WidgetTester tester, Widget child,
    {HomeSetupState setup = const HomeSetupState(loaded: true),
    List<Override> extra = const []}) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      homeSetupProvider.overrideWith(() => _Setup(setup)),
      ...extra,
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('Saved messages is the first row; empty DMs show no time',
      (tester) async {
    await _pump(
      tester,
      const CustomScrollView(slivers: [HomeConversations(query: '')]),
    );
    final rows = tester
        .widgetList<ConversationRow>(find.byType(ConversationRow))
        .toList();
    expect(rows, isNotEmpty);
    expect(rows.first.title, 'Saved messages');
    for (final row in rows.skip(1)) {
      expect(row.time, isNull,
          reason: '${row.title} has no messages, so no time');
    }
    expect(find.textContaining('2000'), findsNothing);
  });

  testWidgets('the phrase reminder moves to Needs Attention once hidden',
      (tester) async {
    await _pump(
      tester,
      const HomeAttention(),
      setup: const HomeSetupState(loaded: true, hidden: true),
    );
    expect(find.text("Your recovery phrase isn't backed up yet"),
        findsOneWidget);
  });

  testWidgets('a saved phrase needs no reminder', (tester) async {
    await _pump(
      tester,
      const HomeAttention(),
      setup: const HomeSetupState(loaded: true, hidden: true, phraseSaved: true),
    );
    expect(find.text("Your recovery phrase isn't backed up yet"),
        findsNothing);
  });

  testWidgets('while the checklist shows, it carries the phrase step alone',
      (tester) async {
    await _pump(tester, const HomeAttention());
    expect(find.text("Your recovery phrase isn't backed up yet"),
        findsNothing);
  });

  testWidgets('a device another of ours added needs attention, never as a contact',
      (tester) async {
    const own = verification_api.SecurityAlertFfi(
      alertId: 'own_device_added:me:$_added:$_desk',
      peerId: 'me',
      kind: SecurityAlertKind.ownDeviceAdded,
      detail: '$_added:$_desk',
      createdAt: 0,
    );
    await _pump(tester, const HomeAttention(), extra: [
      securityAlertsProvider.overrideWith(() => _Alerts(const [own])),
      deviceKindProvider.overrideWith(_Kinds.new),
    ]);
    expect(find.text('Desktop added a device'), findsOneWidget);
    expect(find.textContaining('Phone joined your identity'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Verify'), findsNothing, reason: 'our own device is not a contact to verify');

    final container = ProviderScope.containerOf(tester.element(find.byType(HomeAttention)));
    expect(container.read(peersWithSecurityAlertsProvider), isEmpty);
    expect(container.read(peerSecurityAlertsProvider('me')), isEmpty);
  });

  testWidgets('an added device removed since stays, saying it was removed',
      (tester) async {
    const own = verification_api.SecurityAlertFfi(
      alertId: 'own_device_added:me:$_added:$_desk',
      peerId: 'me',
      kind: SecurityAlertKind.ownDeviceAdded,
      detail: '$_added:$_desk',
      createdAt: 0,
      resolvedAt: 1,
    );
    const contact = verification_api.SecurityAlertFfi(
      alertId: 'new_device:bob:dev',
      peerId: 'bob',
      kind: SecurityAlertKind.newDevice,
      detail: 'dev',
      createdAt: 0,
      resolvedAt: 1,
    );
    await _pump(tester, const HomeAttention(), extra: [
      securityAlertsProvider.overrideWith(() => _Alerts(const [own, contact])),
      deviceKindProvider.overrideWith(_Kinds.new),
    ]);
    expect(find.text('Desktop added a device'), findsOneWidget);
    expect(find.textContaining('has since been removed'), findsOneWidget);
    expect(find.textContaining('added a device and removed it again'), findsOneWidget);
    expect(find.textContaining('added a new device'), findsNothing,
        reason: 'a device removed since is not a new device');
  });
}

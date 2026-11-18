import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart';
import 'package:hollow/src/ui/components/verified_mark.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

import '../helpers/test_app.dart';

/// 0.14.1: a verified contact shows the shield beside their name in the DM
/// header on the phone and the desktop, not only in the profile; and the phone
/// header grows with large text instead of overflowing.
const _bobDevice = 'device_of_bob_123';
const _bob = 'master_of_bob_456';

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() => const DeviceLinkState(links: {_bobDevice: _bob});
}

class _Verified extends VerifiedPeersNotifier {
  _Verified(this.ids);
  final Set<String> ids;
  @override
  Set<String> build() => ids;
}

List<Override> _overrides(Set<String> verified) => hollowTestOverrides(extra: [
      deviceLinkProvider.overrideWith(_Links.new),
      connectionStatusProvider.overrideWith(TestRelayStatus.new),
      verifiedPeersProvider.overrideWith(() => _Verified(verified)),
    ]);

Future<void> _pumpPhone(WidgetTester tester, Set<String> verified,
    {double textScale = 1.0}) async {
  tester.view.physicalSize = const Size(375, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(verified),
    child: MaterialApp(
      navigatorKey: nav,
      theme: HollowThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const Scaffold(body: Text('home')),
    ),
  ));
  unawaited(nav.currentState!.push(hollowMobileRoute<void>(
    settings: const RouteSettings(name: MobileChatRoute.routeName),
    builder: (_) => const MobileChatRoute(peerId: _bobDevice),
  )));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _Api());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  testWidgets('phone: a verified contact shows the mark in the header',
      (tester) async {
    await _pumpPhone(tester, {_bob});
    expect(find.byType(VerifiedMark), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone: no mark for a contact not verified', (tester) async {
    await _pumpPhone(tester, const {});
    expect(find.byType(VerifiedMark), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('phone: the header holds at 2x text', (tester) async {
    await _pumpPhone(tester, {_bob}, textScale: 2.0);
    expect(tester.takeException(), isNull);
    expect(find.byType(VerifiedMark), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('desktop: the header shows the mark only while the profile panel is closed',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: _overrides({_bob}),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: ChatPane(peerId: _bobDevice)),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    // The profile panel is open by default and says "Verified" itself.
    expect(find.byType(VerifiedMark), findsNothing);

    ProviderScope.containerOf(tester.element(find.byType(ChatPane)))
        .read(dmProfilePanelProvider.notifier)
        .state = false;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(VerifiedMark), findsOneWidget);
  });
}

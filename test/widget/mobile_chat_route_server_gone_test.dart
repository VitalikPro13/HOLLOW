import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Every FFI call stays pending, so the page sits in its loading states and
/// nothing fails or retries on a timer.
class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

/// The OS tray a DM page clears on open, absent on the test host.
class _QuietTray extends FlutterLocalNotificationsPlatform {}

class _Servers extends ServerListNotifier {
  final Map<String, ServerInfo> initial;
  _Servers(this.initial);

  @override
  Map<String, ServerInfo> build() => initial;

  /// What a whole-list load writes.
  void replace(Map<String, ServerInfo> next) => state = next;
}

const _home = 'chats-home';
final _server1 = {kServerId1: testServers[kServerId1]!};

/// The Chats tab stand-in with a channel page pushed over it, the way every
/// phone entry point pushes one.
Future<GlobalKey<NavigatorState>> _openPage(
  WidgetTester tester, {
  required Map<String, ServerInfo> servers,
  bool loaded = true,
  MobileChatRoute page = const MobileChatRoute(
    serverId: kServerId1,
    channelId: kChannelId1,
    channelName: 'general',
  ),
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      serverListProvider.overrideWith(() => _Servers(servers)),
      serverListLoadStateProvider
          .overrideWith((_) => (loaded: loaded, error: null)),
    ]),
    child: MaterialApp(
      navigatorKey: nav,
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: Text(_home)),
    ),
  ));
  unawaited(nav.currentState!.push(hollowMobileRoute<void>(
    settings: const RouteSettings(name: MobileChatRoute.routeName),
    builder: (_) => page,
  )));
  await _settle(tester);
  expect(find.byType(MobileChatRoute), findsOneWidget);
  return nav;
}

/// A few frames and the route transition, without waiting for spinners.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.text(_home, skipOffstage: false)));

_Servers _servers(WidgetTester tester) =>
    _container(tester).read(serverListProvider.notifier) as _Servers;

void main() {
  setUpAll(() {
    RustLib.initMock(api: _PendingApi());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  testWidgets('a channel page leaves when its server leaves the list',
      (tester) async {
    await _openPage(tester, servers: _server1);

    // Kicked, banned, deleted or left elsewhere: each ends in this removal.
    _servers(tester).onServerDeleted(kServerId1);
    await _settle(tester);

    expect(find.byType(MobileChatRoute), findsNothing);
    expect(find.text(_home), findsOneWidget);
  });

  testWidgets('a page pushed above the channel page stays when it goes',
      (tester) async {
    final nav = await _openPage(tester, servers: _server1);
    unawaited(nav.currentState!.push(hollowMobileRoute<void>(
      builder: (_) => const Scaffold(body: Text('above')),
    )));
    await _settle(tester);

    _servers(tester).onServerDeleted(kServerId1);
    await _settle(tester);

    expect(find.byType(MobileChatRoute, skipOffstage: false), findsNothing);
    expect(find.text('above'), findsOneWidget);
    nav.currentState!.pop();
    await _settle(tester);
    expect(find.text(_home), findsOneWidget);
  });

  testWidgets('a list still loading never closes the page', (tester) async {
    // A cold-start push tap opens the page before the list is read.
    await _openPage(tester, servers: const {}, loaded: false);
    final servers = _servers(tester);

    // The join event lands ahead of the load, then the load's first map has
    // not caught up with it yet.
    servers.onServerCreated(kServerId1, 'Test Server');
    await _settle(tester);
    servers.replace(const {});
    await _settle(tester);
    expect(find.byType(MobileChatRoute), findsOneWidget);

    servers.replace(_server1);
    _container(tester).read(serverListLoadStateProvider.notifier).state =
        (loaded: true, error: null);
    await _settle(tester);
    expect(find.byType(MobileChatRoute), findsOneWidget);
  });

  testWidgets('a DM page stays when a server leaves the list', (tester) async {
    await _openPage(
      tester,
      servers: _server1,
      page: const MobileChatRoute(peerId: kFriendPeerId1),
    );

    _servers(tester).onServerDeleted(kServerId1);
    await _settle(tester);

    expect(find.byType(MobileChatRoute), findsOneWidget);
  });
}

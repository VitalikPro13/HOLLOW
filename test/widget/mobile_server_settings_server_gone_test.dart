/// A phone's server settings sub-page leaves when its server leaves the list
/// (a kick, a ban, a delete or a leave from any device), and never while the
/// list is still loading.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/leave_with_server.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_server_settings_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/server_settings/pages/members_page.dart';
import 'package:hollow/src/ui/server_settings/pages/roles_page.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Every FFI call stays pending, so no page fails or retries on a timer.
class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => {kServerId1: testServers[kServerId1]!};

  /// What a whole-list load writes.
  void replace(Map<String, ServerInfo> next) => state = next;
}

const _home = 'chats-home';

class _PopCounter extends NavigatorObserver {
  int count = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => count++;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      count++;
}

crdt_api.MemberFfi _m(String id, String name, String role) =>
    crdt_api.MemberFfi(
      peerId: id,
      displayName: name,
      role: role,
      nickname: name,
      twitchUsername: '',
      labels: const [],
    );

List<Override> _overrides({required bool loaded}) => hollowTestOverrides(extra: [
      serverListProvider.overrideWith(_Servers.new),
      serverListLoadStateProvider
          .overrideWith((_) => (loaded: loaded, error: null)),
      myPermissionsProvider(kServerId1)
          .overrideWith((_) async => Permission.all),
      myRoleProvider(kServerId1).overrideWith((_) async => 'owner'),
      serverSettingProvider.overrideWith((ref, a) async => ''),
      serverMembersProvider(kServerId1).overrideWith(
          (_) async => [_m(kLocalPeerId, 'Vitalik', 'owner')]),
      serverLabelsProvider(kServerId1)
          .overrideWith((_) async => const <crdt_api.LabelFfi>[]),
      mutedMembersProvider(kServerId1)
          .overrideWith((_) async => const <crdt_api.MutedMemberFfi>[]),
      bannedMembersProvider(kServerId1).overrideWith((_) async => const []),
      serverEmotesProvider(kServerId1).overrideWith((_) async => const []),
      serverStickersProvider(kServerId1).overrideWith((_) async => const []),
      channelGrantsProvider.overrideWith((ref, a) async => const []),
      serverChannelsProvider(kServerId1)
          .overrideWith((_) async => testChannels),
      rolePermissionsProvider(kServerId1).overrideWith((_) async => {
            for (final role in ['admin', 'moderator', 'member'])
              role: (perms: Permission.all, defaults: Permission.all),
          }),
    ]);

/// The Chats tab stand-in, the server's settings pushed over it the way the
/// chat list pushes them, and [page] opened from there.
Future<void> _openSubPage(WidgetTester tester, ServerSettingsPage page,
    {bool loaded = true}) async {
  tester.view.physicalSize = const Size(400, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(loaded: loaded),
    child: MaterialApp(
      navigatorKey: nav,
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: Text(_home)),
    ),
  ));
  unawaited(nav.currentState!.push(hollowMobileRoute<void>(
    builder: (_) => const MobileServerSettingsRoute(serverId: kServerId1),
  )));
  await _settle(tester);
  await tester.tap(find.byKey(ValueKey(page)));
  await _settle(tester);
  expect(_subPage(page), findsOneWidget, reason: page.label);
}

/// A sub-page is the second settings page on the stack, titled by its page.
Finder _subPage(ServerSettingsPage page) => find.byWidgetPredicate(
    (w) => w is MobileSettingsSubPage && w.title == page.label);

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
  setUpAll(() => RustLib.initMock(api: _PendingApi()));

  for (final page in ServerSettingsPage.values) {
    testWidgets('${page.label} leaves when its server leaves the list',
        (tester) async {
      await _openSubPage(tester, page);

      // Kicked, banned, deleted or left elsewhere: each ends in this removal.
      _servers(tester).onServerDeleted(kServerId1);
      await _settle(tester);

      expect(_subPage(page), findsNothing);
      expect(find.text('This server is gone'), findsOneWidget);
    });
  }

  testWidgets('a page at the root of the stack is never popped',
      (tester) async {
    final popped = _PopCounter();
    await tester.pumpWidget(ProviderScope(
      overrides: _overrides(loaded: true),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        navigatorObservers: [popped],
        home: const LeaveWithServer(
            serverId: kServerId1, child: Scaffold(body: Text(_home))),
      ),
    ));
    await tester.pump();

    _servers(tester).onServerDeleted(kServerId1);
    await _settle(tester);

    expect(popped.count, 0);
    expect(find.text(_home), findsOneWidget);
  });

  testWidgets('a list still loading never closes a sub-page', (tester) async {
    await _openSubPage(tester, ServerSettingsPage.members, loaded: false);
    final servers = _servers(tester);

    // The load's first map has not caught up with the server yet.
    servers.replace(const {});
    await _settle(tester);
    expect(_subPage(ServerSettingsPage.members), findsOneWidget);

    servers.replace({kServerId1: testServers[kServerId1]!});
    _container(tester).read(serverListLoadStateProvider.notifier).state =
        (loaded: true, error: null);
    await _settle(tester);
    expect(_subPage(ServerSettingsPage.members), findsOneWidget);
  });
}

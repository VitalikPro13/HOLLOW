// The phone's hold (t14-iospush): flagged servers stay off the list while the
// phone is away and until the relay handed over what our computers said, but
// the hold never acts as if the person left a server, and it always ends.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/api/age_gate.dart';
import 'package:hollow/src/rust/api/crdt.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/leave_with_server.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';

class _Api implements RustLibApi {
  List<ServerFfi> servers = const [];
  AgeGateFfi status = const AgeGateFfi(
      platform: 'android',
      phonesAllow: false,
      localAllow: false,
      allowedHere: false,
      asked: false);

  @override
  Future<List<ServerFfi>> crateApiCrdtGetJoinedServers() async => servers;

  @override
  Future<AgeGateFfi> crateApiAgeGateAgeGateStatus() async => status;

  @override
  Future<List<String>> crateApiAgeGateAgeHiddenServers() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

final _api = _Api();

/// A gate that starts where the test says and never asks Rust.
class _Gate extends AgeGateNotifier {
  _Gate(this.initial);
  final AgeGateState initial;

  @override
  AgeGateState build() => initial;

  @override
  Future<void> load() async {}

  void set(AgeGateState next) => state = next;
}

/// The real gate (its listeners and the cap) from a held start.
class _LiveGate extends AgeGateNotifier {
  _LiveGate(this.initial);
  final AgeGateState initial;

  @override
  AgeGateState build() {
    super.build();
    return initial;
  }

  @override
  Future<void> load() async {}
}

ServerFfi _server(String id, {bool nsfw = false, String? name}) => ServerFfi(
    serverId: id,
    name: name ?? id,
    memberCount: 2,
    channelCount: 1,
    isNsfw: nsfw);

const _open = AgeGateState(allowedHere: true);

ProviderContainer _container(AgeGateNotifier Function() gate,
    {AgeGateMode mode = AgeGateMode.phoneRemote,
    List<Override> extra = const []}) {
  final c = ProviderContainer(overrides: [
    ageGateModeProvider.overrideWithValue(mode),
    ageGateProvider.overrideWith(gate),
    ...extra,
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<void> _pushServerPage(WidgetTester tester, ProviderContainer c) async {
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      navigatorKey: nav,
      theme: HollowThemeData.dark(),
      home: const Text('chats'),
    ),
  ));
  nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const LeaveWithServer(
          serverId: 'flagged', child: Text('in the 18+ channel'))));
  await tester.pumpAndSettle();
  expect(find.text('in the 18+ channel'), findsOneWidget, reason: 'setup');
}

void main() {
  setUpAll(() => RustLib.initMock(api: _api));

  group('the hold never closes a page', () {
    testWidgets(
        'an adult reading an allowed 18+ server keeps the page when the phone goes to the background',
        (tester) async {
      _api.servers = [_server('flagged', nsfw: true, name: 'Adult')];
      final c = _container(() => _Gate(_open));
      await c.read(serverListProvider.notifier).loadFromDb();
      expect(c.read(serverListProvider).keys, ['flagged'], reason: 'setup');
      await _pushServerPage(tester, c);

      // What the phone does on AppLifecycleState.paused.
      c.read(ageGateProvider.notifier).hold();
      await tester.pumpAndSettle();
      expect(c.read(serverListProvider), isEmpty,
          reason: 'setup: the hold took it off the list');
      expect(find.text('in the 18+ channel'), findsOneWidget,
          reason: 'the hold pops every page open on an allowed 18+ server');
    });

    testWidgets('a computer turning 18+ off still closes the page while held',
        (tester) async {
      _api.servers = [_server('flagged', nsfw: true)];
      final c = _container(() => _Gate(_open));
      await c.read(serverListProvider.notifier).loadFromDb();
      await _pushServerPage(tester, c);
      c.read(ageGateProvider.notifier).hold();
      await tester.pumpAndSettle();

      // What _onAgeGateChanged does: the gate closes, Rust lists it no more.
      (c.read(ageGateProvider.notifier) as _Gate).set(const AgeGateState(
          allowedHere: false, hidden: {'flagged'}, held: true));
      _api.servers = const [];
      await c.read(serverListProvider.notifier).loadFromDb();
      await tester.pumpAndSettle();
      expect(find.text('in the 18+ channel'), findsNothing,
          reason: 'a server the gate hides closes its page');
    });

    testWidgets('a phone whose only server is held is not greeted as new',
        (tester) async {
      _api.servers = [_server('flagged', nsfw: true)];
      final c = _container(() => _Gate(_open), extra: [
        sortedFriendsProvider.overrideWithValue(const []),
      ]);
      c.read(friendsLoadStateProvider.notifier).state =
          (loaded: true, error: null);
      await c.read(serverListProvider.notifier).loadFromDb();
      c.read(ageGateProvider.notifier).hold();
      expect(c.read(serverListProvider), isEmpty, reason: 'setup');

      late bool firstRun;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: Consumer(builder: (context, ref, _) {
          firstRun = homeIsFirstRun(ref);
          return const SizedBox.shrink();
        }),
      ));
      expect(firstRun, isFalse,
          reason: 'a held server is still a joined server');
    });
  });

  group('the hold always ends', () {
    const held = AgeGateState(allowedHere: true, held: true);

    testWidgets('the cap ends the hold only after ten seconds on screen',
        (tester) async {
      final c = _container(() => _LiveGate(held));
      c.read(ageGateProvider);
      final life = c.read(appLifecycleProvider.notifier);

      life.state = AppLifecycleState.paused;
      c.read(ageGateProvider.notifier).hold();
      await tester.pump(const Duration(seconds: 30));
      expect(c.read(ageGateProvider).held, isTrue,
          reason: 'no cap runs in the background, the replay comes after it');

      life.state = AppLifecycleState.resumed;
      await tester.pump(const Duration(seconds: 9));
      expect(c.read(ageGateProvider).held, isTrue,
          reason: 'the relay gets its ten seconds');
      await tester.pump(const Duration(seconds: 2));
      expect(c.read(ageGateProvider).held, isFalse,
          reason: 'a phone that never hears back lists its servers again');
    });

    testWidgets('a cold start on screen ends the hold after the cap',
        (tester) async {
      final c = _container(() => _LiveGate(held));
      c.read(ageGateProvider);
      await tester.pump(const Duration(seconds: 11));
      expect(c.read(ageGateProvider).held, isFalse);
    });

    testWidgets('a refused login ends the hold at once', (tester) async {
      final c = _container(() => _LiveGate(held));
      c.read(ageGateProvider);
      c.read(relayLoginDenialProvider.notifier).state = 'account_denied';
      expect(c.read(ageGateProvider).held, isFalse,
          reason: 'nothing can arrive from a relay that refuses us');
    });

    testWidgets('a relay settled offline ends the hold on screen only',
        (tester) async {
      final c = _container(() => _LiveGate(held));
      c.read(ageGateProvider);
      final life = c.read(appLifecycleProvider.notifier);
      final status = c.read(connectionStatusProvider.notifier);

      life.state = AppLifecycleState.paused;
      c.read(ageGateProvider.notifier).hold();
      status.onRelayConnected();
      status.onRelayDisconnected();
      await tester.pump(ConnectionStatusNotifier.offlineGrace);
      expect(c.read(connectionStatusProvider).relayStatus,
          RelayConnectionStatus.disconnected,
          reason: 'setup');
      expect(c.read(ageGateProvider).held, isTrue,
          reason: 'an offline relay while away says nothing about the return');

      life.state = AppLifecycleState.resumed;
      status.onRelayConnected();
      status.onRelayDisconnected();
      await tester.pump(ConnectionStatusNotifier.offlineGrace);
      expect(c.read(ageGateProvider).held, isFalse,
          reason: 'on screen, an offline relay delivers nothing more');
    });
  });

  group('no hold where nothing can close the gate', () {
    test('a sideloaded phone with its own toggle on is never held', () {
      final c = _container(
          () => _Gate(const AgeGateState(allowedHere: true, localAllow: true)),
          mode: AgeGateMode.phoneLocal);
      c.read(ageGateProvider.notifier).hold();
      expect(c.read(ageGateProvider).held, isFalse);
    });

    test('a sideloaded phone learns its toggle and lets go of the hold',
        () async {
      _api.status = const AgeGateFfi(
          platform: 'android',
          phonesAllow: false,
          localAllow: true,
          allowedHere: true,
          asked: false);
      final c = ProviderContainer(overrides: [
        ageGateModeProvider.overrideWithValue(AgeGateMode.phoneLocal),
      ]);
      addTearDown(c.dispose);
      expect(c.read(ageGateProvider).held, isTrue, reason: 'setup');
      await c.read(ageGateProvider.notifier).load();
      expect(c.read(ageGateProvider).held, isFalse);
    }, skip: Platform.isAndroid);
  });

  group('the held list stays current', () {
    test('a server renamed while held is named by its new name', () async {
      _api.servers = [_server('flagged', nsfw: true, name: 'Old')];
      final c = _container(() => _Gate(_open));
      final list = c.read(serverListProvider.notifier);
      await list.loadFromDb();
      c.read(ageGateProvider.notifier).hold();
      _api.servers = [_server('flagged', nsfw: true, name: 'New')];
      await list.onServerUpdated('flagged');
      expect(list.nameOf('flagged'), 'New');

      list.onServerDeleted('flagged');
      expect(list.nameOf('flagged'), isNull,
          reason: 'a deleted server is gone from the held list too');
    });

    test('a server flagged while held is held, and still named', () async {
      _api.servers = [_server('s', name: 'Plain')];
      final c = _container(() => _Gate(_open));
      final list = c.read(serverListProvider.notifier);
      await list.loadFromDb();
      c.read(ageGateProvider.notifier).hold();
      expect(c.read(serverListProvider).keys, ['s'], reason: 'setup');

      _api.servers = [_server('s', nsfw: true, name: 'Plain')];
      await list.onServerUpdated('s');
      expect(c.read(serverListProvider), isEmpty);
      expect(list.nameOf('s'), 'Plain',
          reason: 'the gate allows it, so a notification names it');
    });
  });

  test('a channel wake whose server cannot be read shows no banner', () {
    final (_, _, level, adult) = kChannelWakeUnknownMeta;
    expect(
        channelWakeShowsFallback(
            posted: false, ageRestricted: adult, notifLevel: level),
        isFalse,
        reason: 'an unread wake may name a hidden 18+ server');
  });
}

// What the phone's hold and the NSFW badge look like (t14-iospush UI review).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/server_name_text.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import 'helpers/test_app.dart';

class _Api implements RustLibApi {
  List<ServerFfi> servers = const [];

  @override
  Future<List<ServerFfi>> crateApiCrdtGetJoinedServers() async => servers;

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

final _api = _Api();

class _Gate extends AgeGateNotifier {
  _Gate(this.initial);
  final AgeGateState initial;

  @override
  AgeGateState build() => initial;

  @override
  Future<void> load() async {}
}

class _SetupShown extends HomeSetupNotifier {
  @override
  HomeSetupState build() => const HomeSetupState(loaded: true);
}

class _NoFriends extends FriendsNotifier {
  @override
  build() => {};
}

class _Listed extends ServerListNotifier {
  _Listed(this.servers);
  final Map<String, ServerInfo> servers;

  @override
  Map<String, ServerInfo> build() => servers;
}

ServerFfi _server(String id, {bool nsfw = false}) => ServerFfi(
    serverId: id, name: id, memberCount: 2, channelCount: 1, isNsfw: nsfw);

ProviderContainer _container(AgeGateState gate) {
  final c = ProviderContainer(overrides: [
    ageGateModeProvider.overrideWithValue(AgeGateMode.phoneRemote),
    ageGateProvider.overrideWith(() => _Gate(gate)),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  setUpAll(() => RustLib.initMock(api: _api));

  test('the NSFW badge is built in one place', () {
    final copies = <String>[];
    for (final f in Directory('lib/src').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      if (f.path.replaceAll('\\', '/').endsWith('components/server_name_text.dart')) {
        continue;
      }
      final src = f.readAsStringSync().replaceAll('\r\n', '\n');
      if (RegExp(r"HollowBadge\(\s*'NSFW'").hasMatch(src)) copies.add(f.path);
    }
    expect(copies, isEmpty, reason: 'use NsfwBadge from server_name_text.dart');
  });

  testWidgets('screen readers hear the badge as age-restricted',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Center(child: NsfwBadge())));
    expect(find.bySemanticsLabel('Age-restricted'), findsOneWidget);
    expect(find.bySemanticsLabel('NSFW'), findsNothing);
    handle.dispose();
  });

  testWidgets(
      'a settings server row keeps its badge beside a long name at 320 px and text scale 2',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const name = 'A server name of exactly forty letters!!';
    expect(name.length, 40, reason: 'setup');
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: const MediaQuery(
        data: MediaQueryData(
            size: Size(320, 640), textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: SettingsDensity(
            touch: true,
            child: SettingsRow(
              leading: SizedBox.square(dimension: 32),
              title: name,
              titleWidget: ServerNameText(name, isNsfw: true),
              subtitle: '1 channel set differently',
              trailing: SizedBox(width: 72, height: 32),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull, reason: 'no overflow');
    final badge = tester.getRect(find.text('NSFW'));
    final title = tester.getRect(find.text(name));
    expect(badge.left >= 0 && badge.right <= 320, isTrue,
        reason: 'badge on screen: $badge');
    expect(badge.left >= title.right, isTrue,
        reason: 'the badge sits after the name: $badge vs $title');
    expect(badge.top < title.bottom && badge.bottom > title.top, isTrue,
        reason: 'the badge stays on the name line: $badge vs $title');
    expect(tester.widget<Text>(find.text(name)).maxLines, 1);
  });

  group('the hold notice', () {
    test('shows only while the hold keeps a flagged server off the list',
        () async {
      _api.servers = [_server('clean'), _server('flagged', nsfw: true)];
      final c = _container(const AgeGateState(allowedHere: true));
      await c.read(serverListProvider.notifier).loadFromDb();
      expect(c.read(ageHoldHidesServersProvider), isFalse);

      c.read(ageGateProvider.notifier).hold();
      expect(c.read(ageHoldHidesServersProvider), isTrue);
      expect(c.read(keptServersProvider).keys,
          containsAll(['clean', 'flagged']),
          reason: 'held, not left');
      expect(c.read(heldServersProvider).keys, ['flagged']);

      c.read(ageGateProvider.notifier).release();
      await Future<void>.delayed(Duration.zero);
      expect(c.read(ageHoldHidesServersProvider), isFalse);
      expect(c.read(heldServersProvider), isEmpty);
    });

    test('says nothing on a phone whose gate is closed', () async {
      _api.servers = [_server('clean'), _server('flagged', nsfw: true)];
      final c = _container(const AgeGateState(allowedHere: false));
      await c.read(serverListProvider.notifier).loadFromDb();
      c.read(ageGateProvider.notifier).hold();
      expect(c.read(ageGateProvider).held, isTrue, reason: 'setup');
      expect(c.read(ageHoldHidesServersProvider), isFalse,
          reason: 'the gate hides it, not the hold');
      expect(c.read(keptServersProvider).keys, ['clean']);
    });

    test('says nothing while held with no flagged server', () async {
      _api.servers = [_server('clean')];
      final c = _container(const AgeGateState(allowedHere: true));
      await c.read(serverListProvider.notifier).loadFromDb();
      c.read(ageGateProvider.notifier).hold();
      expect(c.read(ageHoldHidesServersProvider), isFalse);
    });

    // What the Chats tab shows for one flagged server, held or listed.
    Future<String> pumpChats(WidgetTester tester, {required bool held}) async {
      tester.view.physicalSize = const Size(400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const server = ServerInfo(
          serverId: 'flagged', name: 'flagged', memberCount: 2, isNsfw: true);
      await tester.pumpWidget(ProviderScope(
        key: UniqueKey(),
        overrides: hollowTestOverrides(extra: [
          ageGateModeProvider.overrideWithValue(AgeGateMode.phoneRemote),
          ageGateProvider.overrideWith(
              () => _Gate(AgeGateState(allowedHere: true, held: held))),
          if (held)
            heldServersProvider.overrideWithValue({'flagged': server})
          else
            serverListProvider.overrideWith(() => _Listed({'flagged': server})),
          homeSetupProvider.overrideWith(_SetupShown.new),
          friendsProvider.overrideWith(_NoFriends.new),
        ]),
        child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: const Scaffold(body: MobileChatsTab())),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Get Set Up'), findsOneWidget, reason: 'setup');
      final count = find.textContaining(' / ');
      expect(count, findsOneWidget, reason: 'setup');
      return tester.widget<Text>(count).data!;
    }

    testWidgets(
        'a phone holding its only server keeps the filters and the server step done',
        (tester) async {
      final listedCount = await pumpChats(tester, held: false);
      final heldCount = await pumpChats(tester, held: true);
      expect(find.text(kAgeHoldNoticeText), findsOneWidget, reason: 'setup');
      expect(find.text('Unread'), findsOneWidget,
          reason: 'the filters stay while the server is only held');
      expect(find.text('Join or create a server'), findsNothing,
          reason: 'the checklist does not open up while held');
      expect(heldCount, listedCount,
          reason: 'a held server still counts as joined');
    });

    testWidgets('reads as one plain line', (tester) async {
      await tester.pumpWidget(MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(body: AgeHoldNotice())));
      expect(find.text(kAgeHoldNoticeText), findsOneWidget);
      expect(kAgeHoldNoticeText.contains('—'), isFalse);
      expect(kAgeHoldNoticeText.contains(':'), isFalse);
    });
  });
}

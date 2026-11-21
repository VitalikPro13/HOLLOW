// Home's "Finish restoring your identity" after a Welcome phrase restore
// (PHRASE_RESTORE_DESIGN 5, 6.2): when it shows, which version, and when the
// set-aside retry is offered.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/api/roster.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/home_restore_card.dart';

const _day = Duration(days: 1);

class _Api implements RustLibApi {
  WelcomeRestoreState? mark;
  String? done;
  bool mayRust = true;
  Object? setAsideFails;
  int setAsides = 0;
  final saved = <String, String>{};

  @override
  Future<WelcomeRestoreState?> crateApiRosterWelcomeRestoreState() async =>
      mark;

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      key == kRestoreCardDoneKey ? done : null;

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    saved[key] = value;
    if (key == kRestoreCardDoneKey) done = value;
  }

  @override
  Future<bool> crateApiIdentityMaySetAsideThisIdentity() async => mayRust;

  @override
  Future<void> crateApiIdentitySetAsideThisIdentity() async {
    setAsides++;
    if (setAsideFails != null) throw setAsideFails!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Friends extends FriendsNotifier {
  final Map<String, FriendInfo> friends;
  _Friends(this.friends);
  @override
  Map<String, FriendInfo> build() => friends;
}

WelcomeRestoreState _mark(String branch,
        {Duration ago = Duration.zero, bool noWait = false}) =>
    WelcomeRestoreState(
      atMs: DateTime.now().subtract(ago).millisecondsSinceEpoch,
      branch: branch,
      empty: true,
      noWait: noWait,
    );

final _api = _Api();

void main() {
  setUpAll(() => RustLib.initMock(api: _api));
  setUp(() {
    _api
      ..mark = null
      ..done = null
      ..mayRust = true
      ..setAsideFails = null
      ..setAsides = 0
      ..saved.clear();
  });

  Future<void> pump(WidgetTester tester,
      {Map<String, FriendInfo> friends = const {},
      Map<String, ServerInfo> servers = const {},
      bool touch = false}) async {
    tester.view.physicalSize = touch ? const Size(390, 844) : const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        friendsProvider.overrideWith(() => _Friends(friends)),
        keptServersProvider.overrideWithValue(servers),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: SingleChildScrollView(child: HomeRestoreCard(touch: touch)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('restoreCardShows', () {
    final now = DateTime.now();
    test('no mark, no card', () {
      expect(restoreCardShows(null, now: now), isFalse);
    });
    test('inside the 30 days, until closed for this mark', () {
      final mark = _mark('admit', ago: const Duration(days: 29));
      expect(restoreCardShows(mark, now: now), isTrue);
      expect(restoreCardShows(mark, now: now, doneFor: '${mark.atMs}'), isFalse);
      expect(restoreCardShows(mark, now: now, doneFor: '${mark.atMs - 1}'),
          isTrue, reason: 'a later restore shows its own card');
    });
    test('not past the 30 days', () {
      final at30 = _mark('admit', ago: const Duration(days: 30));
      expect(restoreCardShows(at30, now: DateTime.now()), isFalse);
      expect(
          restoreCardShows(
              _mark('recover', ago: const Duration(days: 30) - _day), now: now),
          isTrue);
    });
    test('not for a branch this build does not know', () {
      expect(restoreCardShows(_mark('later'), now: now), isFalse);
    });
  });

  test('the retry is offered only while Rust allows it and nobody knows this '
      'identity', () {
    expect(
        setAsideOffered(
            rustAllows: true, acceptedFriend: false, holdsServer: false),
        isTrue);
    expect(
        setAsideOffered(
            rustAllows: false, acceptedFriend: false, holdsServer: false),
        isFalse);
    expect(
        setAsideOffered(
            rustAllows: true, acceptedFriend: true, holdsServer: false),
        isFalse);
    expect(
        setAsideOffered(
            rustAllows: true, acceptedFriend: false, holdsServer: true),
        isFalse);
  });

  test('each branch has its own lines', () {
    final admit = restoreCardLines(PhraseRestoreBranch.admit, noWait: true);
    expect(admit.first, startsWith('Add your friends again. They accept you '
        'right away, and most servers'));
    expect(admit, contains(startsWith('If a request still shows as sent')));
    expect(admit, contains(startsWith('If someone else might have your old device')));
    expect(admit, isNot(contains(startsWith('A device restored from a backup'))));

    final recover = restoreCardLines(PhraseRestoreBranch.recover, noWait: false);
    expect(recover.first, 'Add your friends again. They accept you right away.');
    expect(recover, contains(startsWith('Hollow asks the members')));
    expect(recover,
        isNot(contains(startsWith('If someone else might have your old device'))));
    expect(recover, isNot(contains(startsWith('A device restored from a backup'))));
    expect(restoreCardLines(PhraseRestoreBranch.recover, noWait: true),
        contains(startsWith('A device restored from a backup now joins only')));

    for (final lines in [admit, recover]) {
      expect(lines, contains(startsWith('A server on another relay')));
      expect(lines.last, startsWith('If a friend gets a new friend request'));
    }
  });

  testWidgets('no restore mark: nothing on Home', (tester) async {
    await pump(tester);
    expect(find.text('Finish restoring your identity'), findsNothing);
  });

  testWidgets('the No card with the retry while nobody knows this identity',
      (tester) async {
    _api.mark = _mark('admit');
    await pump(tester);
    expect(find.text('Finish restoring your identity'), findsOneWidget);
    expect(find.textContaining('remove it in Settings, under Devices'),
        findsOneWidget);
    expect(find.text('Type my phrase again'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('the Yes card says backups need approval when its recovery did',
      (tester) async {
    _api.mark = _mark('recover', noWait: true);
    await pump(tester, touch: true);
    expect(find.textContaining('Hollow asks the members'), findsOneWidget);
    expect(find.textContaining('joins only when you approve it'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (label, rust, friends, servers) in [
    ('Rust refuses', false, const <String, FriendInfo>{}, const <String, ServerInfo>{}),
    (
      'a friend accepted',
      true,
      {
        'f': const FriendInfo(
            peerId: 'f',
            status: 'accepted',
            direction: '',
            requestedAt: 1,
            updatedAt: 1),
      },
      const <String, ServerInfo>{},
    ),
    (
      'a server holds us',
      true,
      const <String, FriendInfo>{},
      {'s': const ServerInfo(serverId: 's', name: 'Den')},
    ),
  ]) {
    testWidgets('no retry once $label', (tester) async {
      _api
        ..mark = _mark('admit')
        ..mayRust = rust;
      await pump(tester, friends: friends, servers: servers);
      expect(find.text('Finish restoring your identity'), findsOneWidget);
      expect(find.text('Type my phrase again'), findsNothing);
      expect(find.textContaining('may have made a different identity'),
          findsOneWidget, reason: 'the line stays, the button goes');
    });
  }

  testWidgets('a pending request alone keeps the retry', (tester) async {
    _api.mark = _mark('admit');
    await pump(tester, friends: {
      'f': const FriendInfo(
          peerId: 'f',
          status: 'pending',
          direction: 'outgoing',
          requestedAt: 1,
          updatedAt: 1),
    });
    expect(find.text('Type my phrase again'), findsOneWidget);
  });

  testWidgets('Done closes the card for this restore', (tester) async {
    _api.mark = _mark('admit');
    await pump(tester);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(_api.saved[kRestoreCardDoneKey], '${_api.mark!.atMs}');
    expect(find.text('Finish restoring your identity'), findsNothing);
  });

  testWidgets('Set aside sets the identity aside, then restarts',
      (tester) async {
    var relaunched = 0;
    relaunchAfterSetAside = () async => relaunched++;
    _api.mark = _mark('admit');
    await pump(tester);
    await tester.tap(find.text('Type my phrase again'));
    await tester.pumpAndSettle();
    expect(find.text('Type your phrase again?'), findsOneWidget);
    expect(find.textContaining('Nothing is deleted.'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_api.setAsides, 0);

    await tester.tap(find.text('Type my phrase again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set aside'));
    await tester.pumpAndSettle();
    expect(_api.setAsides, 1);
    expect(relaunched, 1);
  });

  testWidgets('a set-aside that fails says so and restarts nothing',
      (tester) async {
    var relaunched = 0;
    relaunchAfterSetAside = () async => relaunched++;
    _api
      ..mark = _mark('admit')
      ..setAsideFails = 'set aside refused: a friend accepted';
    await pump(tester);
    await tester.tap(find.text('Type my phrase again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set aside'));
    await tester.pumpAndSettle();
    expect(find.text("Hollow couldn't set this identity aside. Try again."),
        findsOneWidget);
    expect(relaunched, 0);
  });
}

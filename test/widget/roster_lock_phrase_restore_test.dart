// The roster lock after a phrase restore: "Type your recovery phrase again" when
// the restore came too early (HOL-SEC-218), and the changed words for a device a
// recovery on another device left out (PHRASE_RESTORE_DESIGN 9.3, D3b).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/roster_lock.dart';

const _phrase = 'abandon ability able about above absent absorb abstract '
    'absurd abuse access accident account accuse achieve acid acoustic '
    'acquire across act action actor actress actual';

class _Api implements RustLibApi {
  final joins = <String>[];
  final recoveries = <({List<String> keep, int lostSinceMs})>[];

  @override
  Future<bool> crateApiRosterCheckRecoveryPhrase({required String phrase}) async =>
      true;

  @override
  Future<void> crateApiRosterJoinWithPhrase({required String phrase}) async =>
      joins.add(phrase);

  @override
  Future<void> crateApiRosterRecoverWithPhrase({
    required String phrase,
    required List<String> keep,
    required int lostSinceMs,
  }) async =>
      recoveries.add((keep: keep, lostSinceMs: lostSinceMs));

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Gate extends RosterGateNotifier {
  final RosterGate first;
  _Gate(this.first);
  @override
  RosterGate build() => first;
}

final _api = _Api();

void main() {
  setUpAll(() => RustLib.initMock(api: _api));
  setUp(() {
    _api.joins.clear();
    _api.recoveries.clear();
  });

  Future<void> pump(WidgetTester tester, RosterGate gate) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [rosterGateProvider.overrideWith(() => _Gate(gate))],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const RosterLockScreen(),
      ),
    ));
    await tester.pump();
  }

  Future<void> typeAndConfirm(WidgetTester tester, String confirm) async {
    await tester.enterText(find.byType(EditableText).last, _phrase);
    await tester.pump();
    await tester.tap(find.text(confirm));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an admission that came too early asks for the phrase again and '
      'joins with it', (tester) async {
    await pump(
        tester,
        const RosterGate(
            kind: RosterGateKind.tooEarly, tooEarly: PhraseRestoreBranch.admit));
    expect(find.text('Type your recovery phrase again'), findsOneWidget);
    expect(find.textContaining("Your identity doesn't count this device yet."),
        findsOneWidget);
    expect(find.textContaining('Check the date and time'), findsOneWidget);
    await tester.tap(find.text('Use recovery phrase'));
    await tester.pumpAndSettle();
    expect(find.text('Join with your recovery phrase'), findsOneWidget);
    await typeAndConfirm(tester, 'Join');
    expect(_api.joins, [_phrase]);
    expect(_api.recoveries, isEmpty);
  });

  testWidgets('a recovery that came too early recovers again from the same '
      'moment, keeping only this device', (tester) async {
    await pump(
        tester,
        const RosterGate(
            kind: RosterGateKind.tooEarly,
            tooEarly: PhraseRestoreBranch.recover,
            lostSinceMs: 1700000000000));
    expect(find.text('Type your recovery phrase again'), findsOneWidget);
    await tester.tap(find.text('Use recovery phrase'));
    await tester.pumpAndSettle();
    expect(find.text('When did you last have your other devices?'), findsNothing,
        reason: 'the moment was answered already');
    await typeAndConfirm(tester, 'Keep this device');
    expect(_api.recoveries, hasLength(1));
    expect(_api.recoveries.single.keep, isEmpty);
    expect(_api.recoveries.single.lostSinceMs, 1700000000000);
    expect(_api.joins, isEmpty);
  });

  testWidgets('a device a recovery left out says so, and joins with the phrase',
      (tester) async {
    final at = DateTime(2026, 11, 20, 14, 5);
    await pump(tester,
        RosterGate(kind: RosterGateKind.pending, droppedAt: at));
    expect(find.text('Your recovery phrase was used on another device'),
        findsOneWidget);
    expect(find.textContaining("this device isn't part of your identity"),
        findsOneWidget);
    expect(find.textContaining(RegExp(r'^Since .*Nov 20')), findsOneWidget);
    expect(find.textContaining('restored from a backup'), findsNothing);
    await tester.tap(find.text('Use recovery phrase'));
    await tester.pumpAndSettle();
    await typeAndConfirm(tester, 'Join');
    expect(_api.joins, [_phrase]);
  });

  testWidgets('a restored backup keeps its words', (tester) async {
    await pump(tester, const RosterGate(kind: RosterGateKind.pending));
    expect(find.text('Waiting to join your identity'), findsOneWidget);
    expect(find.textContaining('restored from a backup'), findsOneWidget);
  });
}

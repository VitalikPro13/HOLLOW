// Welcome's "Use your recovery phrase" step (PHRASE_RESTORE_DESIGN 1.1, 6.1):
// the question decides the branch, the words go to Rust once, and its refusals
// and the kept-data outcomes land on the step with the words kept.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/core/services/privacy_screen.dart';
import 'package:hollow/src/rust/api/identity.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_phrase_step.dart';

const _phrase = 'abandon ability able about above absent absorb abstract '
    'absurd abuse access accident account accuse achieve acid acoustic '
    'acquire across act action actor actress actual';

class _Call {
  final String phrase;
  final WelcomeRestoreMode mode;
  final bool checkKept;
  _Call(this.phrase, this.mode, this.checkKept);
}

class _Api implements RustLibApi {
  final calls = <_Call>[];

  /// Answers in order; the last one repeats.
  List<FutureOr<RestoreOutcome> Function()> answers = [
    () => const RestoreOutcome.restored(lockedToKeychain: false),
  ];

  @override
  Future<RestoreOutcome> crateApiIdentityWelcomeRestore({
    required String phrase,
    required WelcomeRestoreMode mode,
    required bool checkKept,
  }) async {
    calls.add(_Call(phrase, mode, checkKept));
    final i = calls.length - 1;
    return answers[i < answers.length ? i : answers.length - 1]();
  }

  @override
  Future<bool> crateApiIdentityProtectNewIdentityByDefault(
          {required String phrase}) =>
      throw StateError('the restore runs the keychain default itself');

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

final class _NoProfiles extends IOOverrides {
  @override
  File createFile(String path) =>
      path.endsWith('profiles.json') || path.endsWith('identity.key')
          ? _Missing(path)
          : super.createFile(path);
}

class _Missing implements File {
  _Missing(this.path);
  @override
  final String path;
  @override
  bool existsSync() => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _api = _Api();

void main() {
  setUpAll(() => RustLib.initMock(api: _api));
  setUp(() {
    _api.calls.clear();
    _api.answers = [() => const RestoreOutcome.restored(lockedToKeychain: false)];
    keptMatchOffersSwitch = () => true;
  });

  /// Opens Welcome past the Terms; [result] gets what it pops.
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1440, 900),
    void Function(WelcomeResult?)? result,
    bool afterSetAside = false,
  }) async {
    IOOverrides.global = _NoProfiles();
    addTearDown(() => IOOverrides.global = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext host;
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Builder(builder: (context) {
          host = context;
          return const SizedBox.expand();
        }),
      ),
    ));
    showWelcomeDialog(host, afterSetAside: afterSetAside)
        .then((r) => result?.call(r));
    await tester.pumpAndSettle();
    if (afterSetAside) return;
    await tester.tap(find.text('Agree and continue'));
    await tester.pumpAndSettle();
  }

  Future<void> openStep(WidgetTester tester,
      {void Function(WelcomeResult?)? result}) async {
    await open(tester, result: result);
    await tester.tap(find.text('Use your recovery phrase'));
    await tester.pumpAndSettle();
  }

  HollowButton restoreButton(WidgetTester tester) => tester.widget<HollowButton>(
      find.ancestor(of: find.text('Restore'), matching: find.byType(HollowButton)));

  Future<void> type(WidgetTester tester, String words) async {
    await tester.enterText(
        find.descendant(
            of: find.byKey(const ValueKey('welcome-phrase-field')),
            matching: find.byType(EditableText)),
        words);
    await tester.pump();
  }

  Future<void> pick(WidgetTester tester, PhraseRestoreBranch branch) async {
    await tester.ensureVisible(find.byKey(ValueKey('phrase-branch-${branch.name}')));
    await tester.tap(find.byKey(ValueKey('phrase-branch-${branch.name}')));
    await tester.pumpAndSettle();
  }

  Future<void> restore(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Restore'));
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester) => tester
      .widget<EditableText>(find.descendant(
          of: find.byKey(const ValueKey('welcome-phrase-field')),
          matching: find.byType(EditableText)))
      .controller
      .text;

  for (final (label, size, platform) in [
    ('desktop', const Size(1440, 900), TargetPlatform.macOS),
    ('phone', const Size(390, 844), TargetPlatform.iOS),
  ]) {
    testWidgets('the phrase row comes after the Terms, last of the three '
        '($label)', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        IOOverrides.global = _NoProfiles();
        addTearDown(() => IOOverrides.global = null);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late BuildContext host;
        await tester.pumpWidget(MaterialApp(
          theme: HollowThemeData.dark(),
          home: Builder(builder: (context) {
            host = context;
            return const SizedBox.expand();
          }),
        ));
        showWelcomeDialog(host);
        await tester.pumpAndSettle();
        expect(find.text('Use your recovery phrase'), findsNothing,
            reason: 'nothing restores before the Terms are agreed');
        await tester.tap(find.text('Agree and continue'));
        await tester.pumpAndSettle();
        expect(find.text('Use your recovery phrase'), findsOneWidget);
        expect(find.text('If you lost your only device'), findsOneWidget);
        final link = tester.getTopLeft(find.text('Link a device')).dy;
        final backup = tester.getTopLeft(find.text('Restore from a backup')).dy;
        final phrase =
            tester.getTopLeft(find.text('Use your recovery phrase')).dy;
        expect(link < backup && backup < phrase, isTrue,
            reason: 'Link, Backup, Phrase');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('Restore waits for an answer to the question, and on Yes for '
      'the time too', (tester) async {
    await openStep(tester);
    expect(find.text('Could someone else have your old device?'), findsOneWidget);
    await type(tester, _phrase);
    expect(restoreButton(tester).onPressed, isNull,
        reason: 'nothing is preselected');
    expect(find.text('When did you last have it?'), findsNothing);

    await pick(tester, PhraseRestoreBranch.recover);
    expect(find.text('When did you last have it?'), findsOneWidget);
    expect(find.text('Longer ago, or not sure'), findsOneWidget);
    expect(restoreButton(tester).onPressed, isNull,
        reason: 'a recovery needs the moment to judge the old device from');

    await pick(tester, PhraseRestoreBranch.admit);
    expect(find.text('When did you last have it?'), findsNothing,
        reason: 'an admission drops nobody');
    expect(restoreButton(tester).onPressed, isNotNull);

    await type(tester, '   ');
    expect(restoreButton(tester).onPressed, isNull);
  });

  testWidgets('No restores as an admission and pops restored_phrase',
      (tester) async {
    WelcomeResult? popped;
    await openStep(tester, result: (r) => popped = r);
    await pick(tester, PhraseRestoreBranch.admit);
    await type(tester, '  ${_phrase.toUpperCase()}  ');
    await restore(tester);

    expect(_api.calls, hasLength(1));
    final call = _api.calls.single;
    expect(call.mode, const WelcomeRestoreMode.admit());
    expect(call.checkKept, isTrue, reason: 'the kept-data check comes first');
    expect(call.phrase, _phrase, reason: 'one space, lower case');
    expect(popped?.action, 'restored_phrase');
    expect(popped?.branch, PhraseRestoreBranch.admit);
    expect(popped?.agreedTerms, isTrue);
  });

  testWidgets('Yes restores as a recovery from the earliest moment of the '
      'answer', (tester) async {
    WelcomeResult? popped;
    await openStep(tester, result: (r) => popped = r);
    await pick(tester, PhraseRestoreBranch.recover);
    await tester.ensureVisible(find.text('Longer ago, or not sure'));
    await tester.tap(find.text('Longer ago, or not sure'));
    await tester.pumpAndSettle();
    await type(tester, _phrase);
    await restore(tester);

    expect(_api.calls.single.mode,
        const WelcomeRestoreMode.recover(lostSinceMs: 0));
    expect(popped?.branch, PhraseRestoreBranch.recover);
  });

  testWidgets('Yes in the last 7 days judges from seven days back',
      (tester) async {
    await openStep(tester);
    await pick(tester, PhraseRestoreBranch.recover);
    final before = DateTime.now().subtract(const Duration(days: 7));
    await tester.ensureVisible(find.text('In the last 7 days'));
    await tester.tap(find.text('In the last 7 days'));
    await tester.pumpAndSettle();
    await type(tester, _phrase);
    await restore(tester);
    final mode = _api.calls.single.mode as WelcomeRestoreMode_Recover;
    expect(mode.lostSinceMs, closeTo(before.millisecondsSinceEpoch, 60000));
  });

  for (final (error, text) in [
    ('phrase_words:12', 'A recovery phrase is 24 words. This one has 12.'),
    ('phrase_word:7',
        "Word 7 isn't a recovery phrase word. Check how it's spelled."),
    ('phrase_checksum',
        "These words aren't a recovery phrase. Check each word and the order."),
  ]) {
    testWidgets('Rust refusing with $error says so at the field and keeps the '
        'words', (tester) async {
      _api.answers = [() => throw error];
      WelcomeResult? popped;
      await openStep(tester, result: (r) => popped = r);
      await pick(tester, PhraseRestoreBranch.admit);
      await type(tester, _phrase);
      await restore(tester);
      expect(find.text(text), findsOneWidget);
      expect(fieldText(tester), _phrase);
      expect(popped, isNull);
      expect(find.text('Restore with your recovery phrase'), findsOneWidget);
    });
  }

  testWidgets('a success drops the typed words', (tester) async {
    await openStep(tester);
    await pick(tester, PhraseRestoreBranch.admit);
    await type(tester, _phrase);
    final field = tester.widget<EditableText>(find.descendant(
        of: find.byKey(const ValueKey('welcome-phrase-field')),
        matching: find.byType(EditableText)));
    await restore(tester);
    expect(field.controller.text, isEmpty);
  });

  testWidgets('the whole step is a secret screen', (tester) async {
    await openStep(tester);
    expect(
        find.ancestor(
            of: find.text('Could someone else have your old device?'),
            matching: find.byType(SecretScreen)),
        findsOneWidget);
  });

  testWidgets('Back returns to the first screen', (tester) async {
    await openStep(tester);
    await tester.tap(find.bySemanticsLabel('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Create an identity'), findsOneWidget);
    expect(find.text('Could someone else have your old device?'), findsNothing);
  });

  testWidgets('kept data the words open offers Switch to it and Restore here '
      'anyway, which restores without the check', (tester) async {
    _api.answers = [
      () => const RestoreOutcome.keptMatch(
          path: '/data/hollow-old-2026-11-02', profileName: 'Mira'),
      () => const RestoreOutcome.restored(lockedToKeychain: false),
    ];
    WelcomeResult? popped;
    await openStep(tester, result: (r) => popped = r);
    await pick(tester, PhraseRestoreBranch.admit);
    await type(tester, _phrase);
    await restore(tester);

    expect(find.text('Your data is still here'), findsOneWidget);
    expect(find.textContaining('in the profile Mira.'), findsOneWidget);
    expect(find.text('Switch to it'), findsOneWidget);
    expect(popped, isNull, reason: 'nothing landed yet');

    await tester.tap(find.text('Restore here anyway'));
    await tester.pumpAndSettle();
    expect(_api.calls.map((c) => c.checkKept), [true, false]);
    expect(popped?.action, 'restored_phrase');
  });

  testWidgets('a kept folder no profile lists is named by its day',
      (tester) async {
    _api.answers = [
      () => const RestoreOutcome.keptMatch(path: '/data/hollow-old-2026-11-02'),
    ];
    await openStep(tester);
    await pick(tester, PhraseRestoreBranch.admit);
    await type(tester, _phrase);
    await restore(tester);
    expect(find.textContaining('in the profile Old data from'), findsOneWidget);
    await tester.tap(find.text('Restore here anyway'));
    await tester.pumpAndSettle();
  });

  testWidgets('where no profile can be switched to, a match restores here',
      (tester) async {
    keptMatchOffersSwitch = () => false;
    _api.answers = [
      () => const RestoreOutcome.keptMatch(path: '/data/hollow-old-2026-11-02'),
      () => const RestoreOutcome.restored(lockedToKeychain: false),
    ];
    WelcomeResult? popped;
    await openStep(tester, result: (r) => popped = r);
    await pick(tester, PhraseRestoreBranch.admit);
    await type(tester, _phrase);
    await restore(tester);
    expect(find.text('Your data is still here'), findsNothing);
    expect(_api.calls.map((c) => c.checkKept), [true, false]);
    expect(popped?.action, 'restored_phrase');
  });

  testWidgets('kept data the words do not open warns: Check the words goes '
      'back to the field, Restore anyway restores', (tester) async {
    _api.answers = [
      () => const RestoreOutcome.keptNoneOpens(),
      () => const RestoreOutcome.keptNoneOpens(),
      () => const RestoreOutcome.restored(lockedToKeychain: false),
    ];
    WelcomeResult? popped;
    await openStep(tester, result: (r) => popped = r);
    await pick(tester, PhraseRestoreBranch.admit);
    await type(tester, _phrase);
    await restore(tester);

    expect(find.text('Check your recovery phrase'), findsOneWidget);
    final check = tester.widget<HollowButton>(find.ancestor(
        of: find.text('Check the words'), matching: find.byType(HollowButton)));
    expect(check.variant, HollowButtonVariant.filled);
    await tester.tap(find.text('Check the words'));
    await tester.pumpAndSettle();
    expect(find.text('Check your recovery phrase'), findsNothing);
    expect(fieldText(tester), _phrase);
    expect(popped, isNull);
    expect(_api.calls.map((c) => c.checkKept), [true]);

    await restore(tester);
    await tester.tap(find.text('Restore anyway'));
    await tester.pumpAndSettle();
    expect(_api.calls.map((c) => c.checkKept), [true, true, false]);
    expect(popped?.action, 'restored_phrase');
  });

  testWidgets('after a set-aside Welcome opens on the step and says why',
      (tester) async {
    await open(tester, afterSetAside: true);
    expect(find.text('Could someone else have your old device?'), findsOneWidget);
    expect(find.textContaining('The identity those words made is set aside'),
        findsOneWidget);
  });

  test('restoreReady needs a branch, a time on Yes, and words', () {
    expect(restoreReady(branch: null, lostSinceMs: 0, typed: 'a'), isFalse);
    expect(
        restoreReady(
            branch: PhraseRestoreBranch.admit, lostSinceMs: null, typed: 'a'),
        isTrue);
    expect(
        restoreReady(
            branch: PhraseRestoreBranch.recover, lostSinceMs: null, typed: 'a'),
        isFalse);
    expect(
        restoreReady(
            branch: PhraseRestoreBranch.recover, lostSinceMs: 0, typed: 'a'),
        isTrue);
    expect(
        restoreReady(
            branch: PhraseRestoreBranch.admit, lostSinceMs: null, typed: ' '),
        isFalse);
  });

  test('the restore mode follows the branch', () {
    expect(welcomeRestoreMode(PhraseRestoreBranch.admit, lostSinceMs: 5),
        const WelcomeRestoreMode.admit());
    expect(welcomeRestoreMode(PhraseRestoreBranch.recover, lostSinceMs: 5),
        const WelcomeRestoreMode.recover(lostSinceMs: 5));
  });
}

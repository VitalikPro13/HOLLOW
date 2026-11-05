import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/roster.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/dialogs/recovery_phrase_dialogs.dart';

import '../helpers/test_app.dart';

const _right =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
const _wrong =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon';

/// Rust as the phrase dialogs see it: one phrase is this identity's.
class _PhraseApi implements RustLibApi {
  final checked = <String>[];
  final joined = <String>[];
  final keptAsks = <int>[];
  final recoveries = <(List<String>, int)>[];
  List<String>? keptByDefault = const [];

  @override
  Future<List<String>> crateApiRosterRecoveryKeptByDefault(
      {required int lostSinceMs}) async {
    keptAsks.add(lostSinceMs);
    final kept = keptByDefault;
    if (kept == null) throw Exception('roster unreadable');
    return kept;
  }

  @override
  Future<void> crateApiRosterRecoverWithPhrase(
      {required String phrase,
      required List<String> keep,
      required int lostSinceMs}) async {
    recoveries.add(([...keep]..sort(), lostSinceMs));
  }

  @override
  Future<bool> crateApiRosterCheckRecoveryPhrase({required String phrase}) async {
    checked.add(phrase);
    return phrase == _right;
  }

  @override
  Future<void> crateApiRosterJoinWithPhrase({required String phrase}) async {
    joined.add(phrase);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The places a recovery phrase is typed (design ID-1): a wrong phrase says so on
/// the field and leaves the dialog usable, so the person can fix it and go on.
void main() {
  final api = _PhraseApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.checked.clear();
    api.joined.clear();
    api.keptAsks.clear();
    api.recoveries.clear();
    api.keptByDefault = const [];
  });

  late BuildContext host;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (context) {
          host = context;
          return const SizedBox.expand();
        })),
      ),
    ));
  }

  testWidgets('a wrong phrase is said on the field and the next try goes through',
      (tester) async {
    await pumpHost(tester);
    final result = showCheckPhraseDialog(host);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _wrong);
    await tester.pump();
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.text(kWrongPhraseText), findsOneWidget);

    await tester.enterText(find.byType(TextField), '  ${_right.toUpperCase()}  ');
    await tester.pump();
    expect(find.text(kWrongPhraseText), findsNothing);
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();

    expect(api.checked, [_wrong, _right], reason: 'typed as Rust reads it: trimmed, lower case');
    expect(await result, isTrue);
    expect(find.text('Check your recovery phrase'), findsNothing);
  });

  testWidgets('joining with a wrong phrase joins nothing, the right one joins',
      (tester) async {
    await pumpHost(tester);
    final result = showJoinWithPhraseDialog(host);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _wrong);
    await tester.pump();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text(kWrongPhraseText), findsOneWidget);
    expect(api.joined, isEmpty);

    await tester.enterText(find.byType(TextField), _right);
    await tester.pump();
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(api.joined, [_right]);
    expect(await result, isTrue);
  });

  RosterDevice device(String id, {bool self = false}) => RosterDevice(
      devicePeerId: id, state: 'member', thisDevice: self, added: const []);

  RosterStatus status(List<String> others) => RosterStatus(
        member: true,
        protected: true,
        backupWait: false,
        devices: [device('me', self: true), for (final id in others) device(id)],
      );

  /// Opens the dialog with the phrase typed; the record holds what it returns.
  Future<({Future<bool> done})> openRecovery(
      WidgetTester tester, List<String> others) async {
    await pumpHost(tester);
    final result = showRecoverWithPhraseDialog(host,
        status: status(others),
        title: 'Use your recovery phrase',
        body: 'Body.',
        confirmLabel: 'Keep these devices');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _right);
    await tester.pump();
    return (done: result);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  bool confirmEnabled(WidgetTester tester) =>
      tester.widget<HollowButton>(find.widgetWithText(HollowButton, 'Keep these devices')).onPressed != null;

  testWidgets(
      'a recovery asks when the other devices were last had, ticks only what '
      'Rust counted before then, and passes that moment on', (tester) async {
    api.keptByDefault = ['phone'];
    final result = (await openRecovery(tester, ['phone', 'laptop'])).done;
    await tester.pumpAndSettle();
    expect(find.text('When did you last have your other devices?'), findsOneWidget);
    expect(find.byKey(const ValueKey('keep-phone')), findsNothing,
        reason: 'the keep list waits for the answer');
    expect(confirmEnabled(tester), isFalse, reason: 'no answer yet');

    final before = DateTime.now();
    await tapKey(tester, 'last-had-last7Days');
    expect(api.keptAsks, hasLength(1));
    final asked = DateTime.fromMillisecondsSinceEpoch(api.keptAsks.single);
    expect(asked.difference(before.subtract(const Duration(days: 7))).inSeconds.abs(),
        lessThan(60), reason: 'the earliest moment of the answer');
    expect(tester.widget<HollowChip>(find.byKey(const ValueKey('keep-phone'))).selected, isTrue);
    expect(tester.widget<HollowChip>(find.byKey(const ValueKey('keep-laptop'))).selected, isFalse);
    expect(confirmEnabled(tester), isTrue);

    await tapKey(tester, 'keep-laptop');
    await tester.ensureVisible(find.text('Keep these devices'));
    await tester.tap(find.text('Keep these devices'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(api.recoveries.single.$1, ['laptop', 'phone']);
    expect(api.recoveries.single.$2, api.keptAsks.single);
  });

  testWidgets('"not sure" judges from 0, and a new answer starts the ticks again',
      (tester) async {
    api.keptByDefault = ['phone'];
    final result = (await openRecovery(tester, ['phone'])).done;
    await tester.pumpAndSettle();
    await tapKey(tester, 'last-had-last30Days');
    expect(tester.widget<HollowChip>(find.byKey(const ValueKey('keep-phone'))).selected, isTrue);

    api.keptByDefault = const [];
    await tapKey(tester, 'last-had-notSure');
    expect(api.keptAsks.last, 0);
    expect(tester.widget<HollowChip>(find.byKey(const ValueKey('keep-phone'))).selected, isFalse);
    await tester.ensureVisible(find.text('Keep these devices'));
    await tester.tap(find.text('Keep these devices'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(api.recoveries.single.$1, isEmpty);
    expect(api.recoveries.single.$2, 0);
  });

  testWidgets('when the counted devices cannot be read nothing is ticked and it says so',
      (tester) async {
    api.keptByDefault = null;
    final result = (await openRecovery(tester, ['phone'])).done;
    await tester.pumpAndSettle();
    await tapKey(tester, 'last-had-yesterday');
    expect(find.text(kKeepUnreadText), findsOneWidget);
    expect(tester.widget<HollowChip>(find.byKey(const ValueKey('keep-phone'))).selected, isFalse);
    await tester.ensureVisible(find.text('Keep these devices'));
    await tester.tap(find.text('Keep these devices'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(api.recoveries.single.$1, isEmpty);
  });

  testWidgets('with no other device nothing is asked and the moment is now',
      (tester) async {
    final before = DateTime.now().millisecondsSinceEpoch;
    final result = (await openRecovery(tester, const [])).done;
    await tester.pumpAndSettle();
    expect(find.text('When did you last have your other devices?'), findsNothing);
    await tester.ensureVisible(find.text('Keep these devices'));
    await tester.tap(find.text('Keep these devices'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(api.keptAsks, isEmpty);
    expect(api.recoveries.single.$2, greaterThanOrEqualTo(before));
  });
}

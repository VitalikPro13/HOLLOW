import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/recovery_phrase_dialogs.dart';

import '../helpers/test_app.dart';

const _right = 'idea limb danger apple parent caught cage rather fun chest fork above';
const _wrong = 'idea limb danger apple parent caught cage rather fun chest fork zoo';

/// Rust as the phrase dialogs see it: one phrase is this identity's.
class _PhraseApi implements RustLibApi {
  final checked = <String>[];
  final joined = <String>[];

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
}

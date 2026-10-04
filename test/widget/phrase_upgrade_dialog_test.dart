import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';

import '../helpers/test_app.dart';

const _stored =
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';

/// Rust as the upgrade dialog sees it: which phrase call Dart makes.
class _UpgradeApi implements RustLibApi {
  final confirmed = <String>[];
  var recoveries = 0;

  @override
  Future<void> crateApiRosterConfirmStoredPhrase({required String phrase}) async {
    confirmed.add(phrase);
  }

  @override
  Future<void> crateApiRosterRecoverWithPhrase(
      {required String phrase, required List<String> keep}) async {
    recoveries++;
  }

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Decision C: the first 0.12 start already made the stored phrase the root, so
/// confirming it erases the copy and signs nothing (a recovery signed now would
/// drop every device vouched since the upgrade).
void main() {
  final api = _UpgradeApi();
  setUpAll(() => RustLib.initMock(api: api));

  testWidgets('confirming the stored phrase never signs a new recovery',
      (tester) async {
    late BuildContext host;
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
    final done = showPhraseUpgradeDialog(host, _stored);
    await tester.pumpAndSettle();
    await tester.tap(find.text("I've written it down"));
    await tester.pumpAndSettle();

    final words = _stored.split(' ');
    final asked = tester
        .widgetList<Text>(find.byWidgetPredicate(
            (w) => w is Text && RegExp(r'^Word \d+$').hasMatch(w.data ?? '')))
        .map((t) => int.parse(t.data!.split(' ').last))
        .toList();
    expect(asked, isNotEmpty);
    final fields = find.byType(TextField);
    for (var i = 0; i < asked.length; i++) {
      await tester.enterText(fields.at(i), words[asked[i] - 1]);
    }
    await tester.pump();
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();

    expect(api.confirmed, [_stored]);
    expect(api.recoveries, 0, reason: 'the upgrade dialog signed a recovery');
    expect(await done, isTrue);
  });
}

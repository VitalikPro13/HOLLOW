import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/twitch.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/server_settings/pages/access_page.dart';

/// The Twitch channel dialog asks for a name and finds the id itself: the raw
/// id field only shows when the lookup cannot answer, and Enter in the name
/// field saves once the id is known.
void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));

  Future<({String name, String id})? Function()> open(WidgetTester tester,
      {String name = '', String id = ''}) async {
    ({String name, String id})? result;
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showHollowDialog<({String name, String id})>(
                  context: context,
                  builder: (_) => TwitchChannelDialog(name: name, id: id),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  testWidgets('the id field stays hidden while the lookup works',
      (tester) async {
    final result = await open(tester);
    expect(find.text('Twitch user ID'), findsNothing);
    await tester.enterText(find.byType(TextField), 'hollowtv');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('Found HollowTV'), findsOneWidget);
    expect(find.text('ID 4242'), findsOneWidget);
    // Enter in the name field saves now that the id is known.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result(), (name: 'HollowTV', id: '4242'));
  });

  testWidgets('a name with no channel shows the error and the id field',
      (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'nobody');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.text('No Twitch channel has that name'), findsOneWidget);
    expect(find.text('Twitch user ID'), findsOneWidget);
  });

  testWidgets('a failed lookup never shows the raw error', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'broken');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('reach the relay'), findsOneWidget);
    expect(find.text('Twitch user ID'), findsOneWidget);
  });
}

class _Api implements RustLibApi {
  @override
  Future<TwitchChannelLookup?> crateApiTwitchTwitchLookupChannel(
      {required String login}) async {
    if (login == 'broken') throw 'relay: connection refused';
    if (login == 'hollowtv') {
      return const TwitchChannelLookup(
          id: '4242', login: 'hollowtv', displayName: 'HollowTV');
    }
    return null;
  }

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

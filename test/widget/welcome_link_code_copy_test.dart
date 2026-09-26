import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';

/// No profile registry and no identities, so no real profile on this machine
/// is ever read into the test.
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

Future<BuildContext> _open(WidgetTester tester) async {
  IOOverrides.global = _NoProfiles();
  addTearDown(() => IOOverrides.global = null);
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext host;
  await tester.pumpWidget(
    MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return host;
}

void main() {
  testWidgets('Link a device names the code as it is: 6 characters', (
    tester,
  ) async {
    showWelcomeDialog(await _open(tester));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('6-digit'),
      findsNothing,
      reason: 'the link code is letters and digits, so "digit" misleads',
    );
    expect(find.textContaining('6-character code'), findsOneWidget);
  });

  testWidgets('creating an identity is the one filled action, and no phrase '
      'restore is offered', (tester) async {
    showWelcomeDialog(await _open(tester));
    await tester.pumpAndSettle();

    final filled = tester
        .widgetList<HollowButton>(find.byType(HollowButton))
        .where((b) => b.variant == HollowButtonVariant.filled)
        .toList();
    expect(filled, hasLength(1));
    expect(find.text('Create an identity'), findsOneWidget);
    expect(find.text('Link a device'), findsOneWidget);
    expect(find.text('Restore from a backup'), findsOneWidget);
    expect(
      find.textContaining('recovery phrase'),
      findsOneWidget,
      reason: 'only the line saying the phrase comes next',
    );
    expect(find.textContaining('Restore from a recovery phrase'), findsNothing);
  });

  testWidgets('a relay that is not a host is refused at the field', (
    tester,
  ) async {
    WelcomeResult? result;
    final host = await _open(tester);
    showWelcomeDialog(host).then((r) => result = r);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel(RegExp('^Change the relay')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) =>
            w is TextField && w.decoration?.hintText == 'relay.anonlisten.com',
      ),
      'not a host!',
    );
    await tester.tap(find.text('Create an identity'));
    await tester.pumpAndSettle();

    expect(result, isNull, reason: 'the node never starts on a typo');
    expect(find.textContaining('Enter a relay address'), findsOneWidget);
  });
}

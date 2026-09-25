import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
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

void main() {
  testWidgets('Link a device names the code as it is: 6 characters',
      (tester) async {
    IOOverrides.global = _NoProfiles();
    addTearDown(() => IOOverrides.global = null);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext host;
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Builder(builder: (context) {
        host = context;
        return const SizedBox.expand();
      })),
    ));
    showWelcomeDialog(host);
    await tester.pumpAndSettle();

    expect(find.textContaining('6-digit'), findsNothing,
        reason: 'the link code is letters and digits, so "digit" misleads');
    expect(find.text('Sync from your other device with a 6-character code'),
        findsOneWidget);
  });
}

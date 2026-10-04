// C-IDENTITY-12: a .hollow file carries the master key and the whole history,
// so its passphrase has a floor; Rust's export holds the same one, as Rust's
// app-lock calls hold the PIN floor (C-LOCAL-04).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/settings/backup_section.dart';

Future<void> _openExport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: HollowThemeData.dark(),
    home: const Scaffold(body: BackupFileRow()),
  ));
  await tester.tap(find.widgetWithText(HollowButton, 'Export'));
  await tester.pumpAndSettle();
  expect(find.text('Export a backup'), findsOneWidget);
}

Future<void> _submit(WidgetTester tester, String passphrase) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), passphrase);
  await tester.enterText(fields.at(1), passphrase);
  await tester.pump();
  await tester.tap(find.widgetWithText(HollowButton, 'Export').last);
  await tester.pumpAndSettle();
}

void main() {
  for (final short in ['hunter2', 'eleven char', '   padded   ']) {
    testWidgets('"$short" is too short to seal a backup', (tester) async {
      await _openExport(tester);
      await _submit(tester, short);

      expect(
          find.text('Use at least $kMinBackupPassphraseChars characters. '
              'A few words work well.'),
          findsOneWidget);
      expect(find.text('Export a backup'), findsOneWidget,
          reason: 'the dialog stays open with what was typed');
    });
  }

  test('Rust holds the same floors', () {
    final storage = File('rust/hollow_core/src/api/storage.rs').readAsStringSync();
    expect(storage,
        contains('MIN_BACKUP_PASSPHRASE_CHARS: usize = $kMinBackupPassphraseChars;'));
    final identity =
        File('rust/hollow_core/src/api/identity.rs').readAsStringSync();
    expect(identity, contains('MIN_PIN_DIGITS: usize = $kMinPinDigits;'));
  });
}

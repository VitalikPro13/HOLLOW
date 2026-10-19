// Apple 1.2: nobody makes, restores or links an identity before agreeing to
// the Terms, and an identity from before the Terms step agrees once.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/terms_agreement.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/terms_agreement_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';

class _SettingsApi implements RustLibApi {
  final Map<String, String> settings = {};
  bool failSave = false;

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      settings[key];

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    if (failSave) throw Exception('store closed');
    settings[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No profile registry and no identities, so no real profile is read.
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

Future<BuildContext> _host(WidgetTester tester, Size size) async {
  IOOverrides.global = _NoProfiles();
  addTearDown(() => IOOverrides.global = null);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext host;
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(body: Builder(builder: (c) {
      host = c;
      return const SizedBox.expand();
    })),
  ));
  return host;
}

const _choices = ['Create an identity', 'Link a device', 'Restore from a backup'];

void main() {
  final api = _SettingsApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.settings.clear();
    api.failSave = false;
  });

  for (final (label, size) in [
    ('desktop', const Size(1440, 900)),
    ('phone', const Size(375, 812)),
  ]) {
    testWidgets('$label: nothing makes an identity before the Terms are agreed',
        (tester) async {
      WelcomeResult? result;
      showWelcomeDialog(await _host(tester, size)).then((r) => result = r);
      await tester.pumpAndSettle();

      for (final choice in _choices) {
        expect(find.text(choice), findsNothing, reason: '$choice before agreeing');
      }
      expect(find.text('Terms of Use'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.textContaining('does not tolerate objectionable content'),
          findsOneWidget);
      final filled = tester
          .widgetList<HollowButton>(find.byType(HollowButton))
          .where((b) => b.variant == HollowButtonVariant.filled)
          .toList();
      expect(filled, hasLength(1));
      expect(
          find.descendant(
              of: find.byWidget(filled.single),
              matching: find.text('Agree and continue')),
          findsOneWidget);

      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();
      for (final choice in _choices) {
        expect(find.text(choice), findsOneWidget, reason: '$choice after agreeing');
      }
      expect(result, isNull, reason: 'agreeing alone makes nothing');

      await tester.tap(find.text('Create an identity'));
      await tester.pumpAndSettle();
      expect(result?.action, 'create_new');
      expect(result?.agreedTerms, isTrue);
    });
  }

  testWidgets('a relinked device agrees before linking too', (tester) async {
    showWelcomeDialog(await _host(tester, const Size(1440, 900)), relinkedTo: 'Old');
    await tester.pumpAndSettle();
    expect(find.text('Link a device'), findsNothing);
    await tester.tap(find.text('Agree and continue'));
    await tester.pumpAndSettle();
    expect(find.text('Link a device'), findsOneWidget);
  });

  group('the one-time question', () {
    test('is due with no agreement or an older one, and not after agreeing',
        () async {
      expect(await termsAgreementDue(), isTrue);
      api.settings[kTermsAgreedKey] = '2026-01-01';
      expect(await termsAgreementDue(), isTrue);
      await recordTermsAgreement();
      expect(api.settings[kTermsAgreedKey], kTermsVersion);
      expect(await termsAgreementDue(), isFalse);
    });

    testWidgets('closes only by agreeing, and saves the version',
        (tester) async {
      var closed = false;
      showTermsAgreementDialog(await _host(tester, const Size(1440, 900)))
          .then((_) => closed = true);
      await tester.pumpAndSettle();
      expect(find.text('Our Terms of Use'), findsOneWidget);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Our Terms of Use'), findsOneWidget,
          reason: 'the scrim and back never dismiss it');
      expect(closed, isFalse);

      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(api.settings[kTermsAgreedKey], kTermsVersion);
      expect(await termsAgreementDue(), isFalse, reason: 'never shown again');
    });

    testWidgets('a failed save keeps it open and says so', (tester) async {
      api.failSave = true;
      showTermsAgreementDialog(await _host(tester, const Size(1440, 900)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agree and continue'));
      await tester.pumpAndSettle();
      expect(find.text('Our Terms of Use'), findsOneWidget);
      expect(find.textContaining('Try again'), findsOneWidget);
      expect(api.settings, isEmpty);
    });
  });

  test('the shell asks only after both locks lift, first of the start offers',
      () {
    final src = File('lib/src/ui/shell/hollow_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final start = src.indexOf('Future<void> _askTermsAgreement() async {');
    expect(start, isNot(-1));
    final body = src.substring(start, src.indexOf('\n  }\n', start));
    final unlocked = body.indexOf('await _untilUnlocked();');
    final belongs = body.indexOf('RosterGateKind.none');
    final ask = body.indexOf('showTermsAgreementDialog(');
    expect(unlocked, greaterThan(-1));
    expect(belongs, greaterThan(unlocked));
    expect(ask, greaterThan(belongs));
    final chain = src.indexOf('Future<void> _offerAfterStart(');
    final asked = src.indexOf('await _askTermsAgreement();', chain);
    expect(asked, isNot(-1), reason: 'the start offers never ask for the Terms');
    expect(asked, lessThan(src.indexOf('await _offerPhraseUpgrade();', chain)));
    expect(src.contains('if (welcomeResult?.agreedTerms == true) {'), isTrue,
        reason: 'a Welcome agreement is saved once the database is open');
  });
}

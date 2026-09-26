import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/game_card_dialog.dart';

/// Game card dialog layout guards. The card must build WITHOUT layout
/// exceptions for both data generations:
///  - legacy bundles (metacritic/genres/sysreq only — the SEARCH_VER ≤9
///    shape every existing board carries), and
///  - v10 bundles (steam_reviews / ttb / themes / modes / franchise).
///
/// Regression: a stretch row in the dialog's unbounded-height scroll context
/// once handed its children an INFINITE height, and the layout exception
/// silently killed the whole main column.
void main() {
  /// Old-shape details: what every pre-v10 baked game actually carries.
  final legacyDetails = GameDetails.fromJson({
    'description': 'Prepare yourself and Embrace The Darkness!',
    'metacritic': 89,
    'achievements': 43,
    'genres': ['Role-playing (RPG)', 'Adventure'],
    'platforms': ['pc', 'playstation', 'xbox'],
    'release_date': '11 Apr, 2016',
    'req_min': 'OS: Windows 7\nProcessor: Intel Core i3-2100',
    'req_rec': 'OS: Windows 10\nProcessor: Intel Core i7-3770',
    'legal': 'DARK SOULS III & ©BANDAI NAMCO Entertainment Inc.',
    'companies': [
      {'name': 'FromSoftware', 'role': 'devpub'},
    ],
  })!;

  /// v10 details: everything the redesigned card can show at once.
  final v10Details = GameDetails.fromJson({
    'description': 'Prepare yourself and Embrace The Darkness!',
    'metacritic': 89,
    'achievements': 43,
    'genres': ['Role-playing (RPG)', 'Adventure'],
    'themes': ['Fantasy', 'Adventure'], // dupe of a genre — must dedup
    'modes': ['Single player', 'Co-operative'],
    'franchise': 'Dark Souls',
    'steam_reviews': {'label': 'Very Positive', 'pos': 512431, 'total': 545000},
    'ttb': {'normally': 115200, 'completely': 324000},
    'platforms': ['pc', 'playstation', 'xbox'],
    'release_date': '11 Apr, 2016',
    'req_min': 'OS: Windows 7',
    'companies': [
      {'name': 'FromSoftware', 'role': 'devpub'},
    ],
  })!;

  Future<void> pumpCard(
    WidgetTester tester,
    GameDetails details, {
    Brightness brightness = Brightness.dark,
    Size size = const Size(1280, 900),
    String? ownerName,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: brightness == Brightness.dark
            ? HollowThemeData.dark()
            : HollowThemeData.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showGameCardDialog(
                  context,
                  name: 'Dark Souls III',
                  year: 2016,
                  blurb: 'The best one.',
                  coverBytes: null,
                  artBytes: null,
                  details: details,
                  assets: const {},
                  ownerName: ownerName,
                ),
                child: const Text('open card'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open card'));
    await tester.pumpAndSettle();
  }

  testWidgets('legacy details build a full card (no layout exception)', (
    tester,
  ) async {
    await pumpCard(tester, legacyDetails);

    // Main column alive: title, byline, About and the Metacritic fact.
    expect(find.text('Dark Souls III'), findsOneWidget);
    expect(find.text('FromSoftware · 11 Apr, 2016'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
    expect(find.text('Metacritic'), findsOneWidget);
    expect(find.text('89'), findsOneWidget);
    // Details pane alive too.
    expect(find.text('Details'), findsOneWidget);
    expect(find.text('Made by'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('v10 details render facts in words, tags and the series', (
    tester,
  ) async {
    await pumpCard(tester, v10Details);

    expect(find.text('Steam reviews'), findsOneWidget);
    expect(find.text('Very positive'), findsOneWidget);
    expect(find.text('Time to beat'), findsOneWidget);
    expect(find.text('About 32 hours'), findsOneWidget);
    expect(find.text('Everything: 90 hours'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    // Tags dedup: 'Adventure' appears exactly once.
    expect(find.text('Adventure'), findsOneWidget);
    expect(find.text('Single player'), findsOneWidget);
  });

  testWidgets('system requirements show, with Minimum and Recommended tabs', (
    tester,
  ) async {
    await pumpCard(tester, legacyDetails);

    expect(find.text('System requirements'), findsOneWidget);
    expect(find.text('Minimum'), findsOneWidget);
    expect(find.text('Windows 7'), findsOneWidget);
    await tester.tap(find.text('Recommended'));
    await tester.pumpAndSettle();
    expect(find.text('Windows 10'), findsOneWidget);
    expect(find.text('Intel Core i7-3770'), findsOneWidget);
  });

  testWidgets('says whose favourite it is, and store chips leave the app', (
    tester,
  ) async {
    final withStore = GameDetails.fromJson({
      'metacritic': 89,
      'stores': {'steam': 'https://store.steampowered.com/app/374320'},
    })!;
    await pumpCard(tester, withStore, ownerName: 'Mira');

    expect(find.text('Mira’s favourite'), findsOneWidget);
    expect(find.text('“The best one.”'), findsOneWidget);
    expect(find.text('Get it on'), findsOneWidget);
    expect(find.text('Steam'), findsOneWidget);
    expect(find.textContaining('saved when Mira pinned it'), findsOneWidget);
  });

  testWidgets('a phone opens a sheet with facts as rows', (tester) async {
    await pumpCard(tester, v10Details, size: const Size(390, 844));

    expect(find.text('Dark Souls III'), findsOneWidget);
    expect(find.text('Very positive'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('light theme builds cleanly too', (tester) async {
    await pumpCard(tester, v10Details, brightness: Brightness.light);
    expect(find.text('Metacritic'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
  });

  test('a notice cut mid-word at the old cap ends on a whole word', () {
    const cut = '©2008 - 2015 Rockstar Games, Inc. Rockstar Games, Rockstar '
        'North, Grand Theft Auto, the GTA Five, and the Rockstar Games R* '
        'marks and logos are trademarks and/o';
    expect(cut.length, 160);
    expect(tidyCopyright(cut), endsWith('trademarks…'));
    expect(tidyCopyright('© 2019 Mobius Digital.'), '© 2019 Mobius Digital.');
  });
}

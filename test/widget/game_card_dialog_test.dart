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
/// Regression: the reception strip's CrossAxisAlignment.stretch row sat in
/// the dialog's unbounded-height scroll context, which handed the tiles a
/// tight INFINITE height — the layout exception silently killed the whole
/// center panel (only the floating right panel survived).
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
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
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

  testWidgets('legacy details build a full card (no layout exception)',
      (tester) async {
    await pumpCard(tester, legacyDetails);

    // Center panel alive: title + About + the Metacritic tile.
    expect(find.text('Dark Souls III'), findsOneWidget);
    expect(find.text('ABOUT'), findsOneWidget);
    expect(find.text('METACRITIC'), findsOneWidget);
    expect(find.text('89'), findsOneWidget);
    // Right panel alive too.
    expect(find.text('PLATFORMS'), findsOneWidget);
    expect(find.text('CREDITS'), findsOneWidget);
  });

  testWidgets('v10 details render strip, tags, series and reviews',
      (tester) async {
    await pumpCard(tester, v10Details);

    expect(find.text('STEAM REVIEWS'), findsOneWidget);
    expect(find.text('Very Positive'), findsOneWidget);
    expect(find.text('TIME TO BEAT'), findsOneWidget);
    expect(find.text('~32h'), findsOneWidget);
    expect(find.textContaining('Dark Souls series'), findsOneWidget);
    // Tag chips: dedup means 'Adventure' appears exactly once.
    expect(find.text('Adventure'), findsOneWidget);
    expect(find.text('Single player'), findsOneWidget);
  });

  testWidgets('system requirements expand on tap (collapsed by default)',
      (tester) async {
    await pumpCard(tester, legacyDetails);

    expect(find.text('SYSTEM REQUIREMENTS'), findsOneWidget);
    expect(find.text('Minimum'), findsNothing);
    await tester.tap(find.text('SYSTEM REQUIREMENTS'));
    await tester.pumpAndSettle();
    expect(find.text('Minimum'), findsOneWidget);
    expect(find.text('Recommended'), findsOneWidget);
  });

  testWidgets('light theme builds cleanly too', (tester) async {
    await pumpCard(tester, v10Details, brightness: Brightness.light);
    expect(find.text('METACRITIC'), findsOneWidget);
    expect(find.text('ABOUT'), findsOneWidget);
  });
}

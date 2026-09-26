import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/game_card_dialog.dart';

/// "After" renders of the redesigned game card: desktop dark and light, the
/// Recommended tab, a card with no key art, a narrow window, and the phone
/// sheet (top and scrolled). Art is generated in-process with coloured EDGE
/// BANDS (orange left, lime right, cyan top, pink bottom), so a crop shows.
///
/// Output: $HOLLOW_SHOT_DIR/redesign_after, else
/// build/ui_screenshots/redesign_after.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${sep}build${sep}ui_screenshots'}'
      '${sep}redesign_after';

  final art = <String, Uint8List>{};

  setUpAll(() async {
    final lucide = await rootBundle.load(
      'packages/lucide_icons_flutter/assets/lucide.ttf',
    );
    await (FontLoader(
      'packages/lucide_icons_flutter/Lucide',
    )..addFont(Future.value(lucide))).load();
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
          ? 'GeistMono'
          : name.startsWith('SimpleIcons')
          ? 'SimpleIcons'
          : null;
      if (family == null) continue;
      final bytes = File(face.path).readAsBytesSync();
      families.putIfAbsent(family, () => []).add(ByteData.view(bytes.buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }

    art['cover'] = await _png(264, 352, (c, s) {
      _gradient(c, s, const Color(0xFFB0662A), const Color(0xFF3A1E0C));
      c.drawCircle(
        Offset(s.width / 2, s.height * 0.6),
        64,
        Paint()..color = const Color(0xFF6FC3DF),
      );
      _crosshair(c, s);
      _edges(c, s, 10);
    });
    art['art'] = await _png(1280, 720, (c, s) {
      _gradient(c, s, const Color(0xFF0E1A2E), const Color(0xFF28406A));
      c.drawCircle(
        Offset(s.width * 0.72, s.height * 0.35),
        150,
        Paint()..color = const Color(0xFFF2A93B),
      );
      _crosshair(c, s);
      _edges(c, s, 24);
    });
    Future<Uint8List> logo(Color color) => _png(200, 80, (c, s) {
      c.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(12)),
        Paint()..color = color,
      );
      c.drawCircle(
        const Offset(40, 40),
        22,
        Paint()..color = const Color(0xFFFFFFFF),
      );
    });
    art['logo1'] = await logo(const Color(0xFF14532D));
    art['logo2'] = await logo(const Color(0xFF7F1D1D));
    art['details'] = Uint8List.fromList(utf8.encode(jsonEncode(_details)));
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(shotKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  /// Lets real image decodes land, then paints them.
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester tester, {
    required Size size,
    bool light = false,
    bool withArt = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    late BuildContext host;
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                host = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    showGameCardDialog(
      host,
      name: 'Outer Wilds',
      year: 2019,
      blurb: 'Twenty-two minutes I will never forget.',
      coverBytes: art['cover'],
      artBytes: withArt ? art['art'] : null,
      details: GameDetails.resolve('details', art)!,
      assets: {
        'h1': art['logo1']!,
        'h2': art['logo2']!,
        'details': art['details']!,
      },
      ownerName: 'Mira',
    );
    await tester.pump();
    await settle(tester);
  }

  testWidgets('game card after: desktop dark, then Recommended', (t) async {
    await open(t, size: const Size(1440, 900));
    await capture(t, 'gamecard_desktop_dark');
    await t.tap(find.text('Recommended'));
    await settle(t, rounds: 2);
    await capture(t, 'gamecard_desktop_requirements_rec');
  }, variant: _desktop);
  testWidgets('game card after: desktop light', (t) async {
    await open(t, size: const Size(1440, 900), light: true);
    await capture(t, 'gamecard_desktop_light');
  }, variant: _desktop);
  testWidgets('game card after: tall window, whole card', (t) async {
    await open(t, size: const Size(1440, 1300));
    await capture(t, 'gamecard_desktop_tall_dark');
  }, variant: _desktop);
  testWidgets('game card after: no key art', (t) async {
    await open(t, size: const Size(1440, 900), withArt: false);
    await capture(t, 'gamecard_desktop_noart_dark');
  }, variant: _desktop);
  testWidgets('game card after: narrow window stacks the pane', (t) async {
    await open(t, size: const Size(800, 900));
    await capture(t, 'gamecard_narrow_800_dark');
  }, variant: _desktop);
  testWidgets('game card after: phone sheet, top and scrolled', (t) async {
    await open(t, size: const Size(390, 844));
    await capture(t, 'gamecard_phone_dark');
    await t.drag(find.text('Outer Wilds').first, const Offset(0, -700));
    await settle(t, rounds: 3);
    await capture(t, 'gamecard_phone_lower_dark');
  }, variant: _phone);
  testWidgets('game card after: phone sheet, light', (t) async {
    await open(t, size: const Size(390, 844), light: true);
    await capture(t, 'gamecard_phone_light');
  }, variant: _phone);
}

final _details = {
  'description':
      'Outer Wilds is an open world mystery about a solar system '
      'trapped in an endless time loop. Explore a hand-crafted system at your '
      'own pace, and piece together what happened before the sun goes out.',
  'metacritic': 85,
  'achievements': 31,
  'genres': ['Adventure', 'Puzzle'],
  'themes': ['Science fiction', 'Open world'],
  'modes': ['Single player'],
  'steam_reviews': {
    'label': 'Overwhelmingly Positive',
    'pos': 98120,
    'total': 102740,
  },
  'ttb': {'normally': 79200, 'completely': 108000},
  'platforms': ['pc', 'playstation', 'xbox', 'nintendo'],
  'release_date': 'May 28, 2019',
  'req_min':
      'OS: Windows 10\nProcessor: Intel Core i5-2300\nMemory: 6 GB RAM\n'
      'Graphics: GeForce GTX 560',
  'req_rec':
      'OS: Windows 10\nProcessor: Intel Core i5-4590\nMemory: 8 GB RAM\n'
      'Graphics: GeForce GTX 970',
  'legal': 'Outer Wilds © Mobius Digital. Published by Annapurna Interactive.',
  'stores': {
    'steam': 'https://store.steampowered.com/app/753640',
    'playstation': 'https://store.playstation.com/',
    'xbox': 'https://www.xbox.com/',
    'nintendo': 'https://www.nintendo.com/',
  },
  'companies': [
    {
      'name': 'Mobius Digital',
      'role': 'dev',
      'logo': 'h1',
      'links': [
        {'kind': 'official', 'url': 'https://www.mobiusdigitalgames.com'},
      ],
    },
    {
      'name': 'Annapurna Interactive',
      'role': 'pub',
      'logo': 'h2',
      'links': [
        {'kind': 'official', 'url': 'https://annapurnainteractive.com'},
      ],
    },
  ],
};

Future<Uint8List> _png(
  int w,
  int h,
  void Function(Canvas c, Size s) paint,
) async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  paint(canvas, Size(w.toDouble(), h.toDouble()));
  final picture = rec.endRecording();
  final image = await picture.toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void _gradient(Canvas c, Size s, Color a, Color b) {
  c.drawRect(
    Offset.zero & s,
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, Offset(s.width, s.height), [
        a,
        b,
      ]),
  );
}

void _crosshair(Canvas c, Size s) {
  final p = Paint()
    ..color = const Color(0xFFFF3B30)
    ..strokeWidth = 3;
  c.drawLine(
    Offset(s.width / 2, s.height / 2 - 30),
    Offset(s.width / 2, s.height / 2 + 30),
    p,
  );
  c.drawLine(
    Offset(s.width / 2 - 30, s.height / 2),
    Offset(s.width / 2 + 30, s.height / 2),
    p,
  );
}

void _edges(Canvas c, Size s, double band) {
  c.drawRect(
    Rect.fromLTWH(0, 0, band, s.height),
    Paint()..color = const Color(0xFFFF7A1A),
  );
  c.drawRect(
    Rect.fromLTWH(s.width - band, 0, band, s.height),
    Paint()..color = const Color(0xFF9BE15D),
  );
  c.drawRect(
    Rect.fromLTWH(0, 0, s.width, band / 2),
    Paint()..color = const Color(0xFF22D3EE),
  );
  c.drawRect(
    Rect.fromLTWH(0, s.height - band / 2, s.width, band / 2),
    Paint()..color = const Color(0xFFFF4FA3),
  );
}

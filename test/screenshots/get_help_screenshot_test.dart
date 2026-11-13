import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/help_resources.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_pages.dart';
import 'package:hollow/src/ui/settings/settings_place.dart';

import '../helpers/test_app.dart';

/// Renders of Settings > Get help: the desktop place (Poland, a picker, an
/// unknown region, light), the phone's settings list and its Get help page,
/// and whole first screens and need pages at desktop and phone widths.
///
/// Output: $HOLLOW_SHOT_DIR/get_help, else build/ui_screenshots/get_help.
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

class _Classic extends LayoutModeNotifier {
  @override
  LayoutMode build() => LayoutMode.classic;
}

class _Choice extends HelpCountryChoiceNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> choose(String? code) async => state = AsyncData(code);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}/build/ui_screenshots'}/get_help';

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
      final file = File('$outDir/$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    required Size size,
    required Widget home,
    String? region = 'PL',
    bool light = false,
    bool classic = false,
    SettingsCategory category = SettingsCategory.help,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = ProviderContainer(
      overrides: hollowTestOverrides(
        extra: [
          deviceRegionProvider.overrideWith(
            (ref) async => region == null
                ? null
                : (code: region, source: HelpRegionSource.locale),
          ),
          helpCountryChoiceProvider.overrideWith(_Choice.new),
          if (classic) layoutModeProvider.overrideWith(_Classic.new),
        ],
      ),
    );
    addTearDown(container.dispose);
    openSettings(container.read, category: category);
    await tester.runAsync(() => container.read(helpResourcesProvider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
            home: home,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  const desk = Size(1280, 900);
  const phone = Size(390, 844);
  const settingsPlace = Scaffold(body: SettingsPlace());

  testWidgets('desktop, Poland', (tester) async {
    await pump(tester, size: desk, home: settingsPlace);
    await capture(tester, 'desktop_pl');
  }, variant: _desktop);

  testWidgets('desktop, Germany notes with links, light', (tester) async {
    await pump(
      tester,
      size: desk,
      home: settingsPlace,
      region: 'DE',
      light: true,
    );
    await capture(tester, 'desktop_de_light');
  }, variant: _desktop);

  testWidgets('desktop, unknown region', (tester) async {
    await pump(tester, size: desk, home: settingsPlace, region: null);
    await capture(tester, 'desktop_unknown');
  }, variant: _desktop);

  testWidgets('desktop, Classic layout, first screen and a need page', (
    tester,
  ) async {
    await pump(tester, size: desk, home: settingsPlace, classic: true);
    await capture(tester, 'classic_pl');
    await tester.tap(find.byKey(const ValueKey('help-open-children')));
    await tester.pumpAndSettle();
    await capture(tester, 'classic_pl_children');
  }, variant: _desktop);

  testWidgets('desktop, narrow 800', (tester) async {
    await pump(tester, size: const Size(800, 900), home: settingsPlace);
    await capture(tester, 'desktop_800');
  }, variant: _desktop);

  testWidgets('desktop, picker with a search', (tester) async {
    await pump(tester, size: desk, home: settingsPlace);
    await tester.tap(find.text('Poland'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'ia');
    await tester.pumpAndSettle();
    await capture(tester, 'desktop_picker');
  }, variant: _desktop);

  testWidgets('desktop, settings search', (tester) async {
    await pump(tester, size: desk, home: settingsPlace);
    await tester.enterText(find.byType(TextField).first, '112');
    await tester.pumpAndSettle();
    await capture(tester, 'desktop_search_112');
  }, variant: _desktop);

  Widget phonePage() => Builder(
    builder: (context) => MobileSettingsSubPage(
      title: 'Get help',
      child: SettingsDensity(
        touch: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: settingsPageFor(SettingsCategory.help),
        ),
      ),
    ),
  );

  testWidgets('phone, settings list', (tester) async {
    final c = await pump(
      tester,
      size: phone,
      home: const Scaffold(body: SafeArea(child: MobileSettingsTab())),
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await tester.pumpAndSettle();
    await capture(tester, 'phone_list');
    // Outlives the relay card's poll.
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    await tester.pump(const Duration(minutes: 2));
  }, variant: _phone);

  testWidgets('phone, Get help top', (tester) async {
    await pump(tester, size: phone, home: phonePage());
    await capture(tester, 'phone_pl_top');
  }, variant: _phone);

  testWidgets('phone, Poland photos page', (tester) async {
    await pump(tester, size: phone, home: phonePage());
    await tester.tap(find.byKey(const ValueKey('help-open-photos')));
    await tester.pumpAndSettle();
    await capture(tester, 'phone_pl_photos');
  }, variant: _phone);

  Future<void> openNeed(WidgetTester tester, String need) async {
    final row = find.byKey(ValueKey('help-open-$need'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  // The first screen in one tall render per case, at desktop 800 and 1280
  // and the phone at 320 with three text scales; then the need pages.
  for (final region in [
    'PL',
    'US',
    'GB',
    'TR',
    'RU',
    'GE',
    'ME',
    'SG',
    'PH',
    'MT',
    null,
  ]) {
    final tag = region?.toLowerCase() ?? 'none';
    for (final width in [800.0, 1280.0]) {
      testWidgets('desktop, $tag first screen at ${width.toInt()}', (
        tester,
      ) async {
        await pump(
          tester,
          size: Size(width, 1800),
          home: settingsPlace,
          region: region,
        );
        await capture(tester, 'first_${tag}_desk${width.toInt()}');
      }, variant: _desktop);
    }
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('phone, $tag first screen at 320 x$scale', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pump(
          tester,
          size: Size(320, 1800 * scale),
          home: phonePage(),
          region: region,
        );
        await capture(tester, 'first_${tag}_phone320_x$scale');
      }, variant: _phone);
    }
  }

  const needs = [
    ('PL', 'crisis'),
    ('PL', 'photos'),
    ('PL', 'children'),
    ('PL', 'websites'),
    ('GB', 'police'),
    ('US', 'crisis'),
    ('US', 'websites'),
    ('RU', 'children'),
    (null, 'photos'),
    ('KR', 'children'),
    ('DE', 'websites'),
    ('ME', 'crisis'),
    ('GE', 'crisis'),
    ('GE', 'children'),
    ('SG', 'crisis'),
    ('PH', 'crisis'),
    ('RU', 'crisis'),
    ('MT', 'crisis'),
    ('GB', 'photos'),
    ('BR', 'websites'),
  ];
  for (final (region, need) in needs) {
    final tag = '${region?.toLowerCase() ?? 'none'}_$need';
    for (final width in [800.0, 1280.0]) {
      testWidgets('desktop, $tag page at ${width.toInt()}', (tester) async {
        await pump(
          tester,
          size: Size(width, 2400),
          home: settingsPlace,
          region: region,
        );
        await openNeed(tester, need);
        await capture(tester, 'need_${tag}_desk${width.toInt()}');
      }, variant: _desktop);
    }
    for (final scale in [1.0, 2.0]) {
      testWidgets('phone, $tag page at 320 x$scale', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pump(
          tester,
          size: Size(320, 2400 * scale),
          home: phonePage(),
          region: region,
        );
        await openNeed(tester, need);
        await capture(tester, 'need_${tag}_phone320_x$scale');
      }, variant: _phone);
    }
  }

  testWidgets('phone, picker', (tester) async {
    await pump(tester, size: phone, home: phonePage());
    final chip = find.text('Poland');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await tester.pumpAndSettle();
    await capture(tester, 'phone_picker');
  }, variant: _phone);
}

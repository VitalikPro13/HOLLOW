import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/device_proof_copy.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/ui/shell/restore_pick_banner.dart';
import 'package:hollow/src/ui/shell/server_strip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/device_proof_fixtures.dart';
import '../helpers/test_app.dart';

/// The pointer back to the restore chooser for servers waiting on the person's
/// pick (F5): the phone's Chats tab, the Dock Home and Classic's strip, dark and
/// light, each one image with the build before on the left and after on the
/// right. Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/f5_pick_row.
class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Setup extends HomeSetupNotifier {
  @override
  HomeSetupState build() =>
      const HomeSetupState(loaded: true, hidden: true, phraseSaved: true);
}

enum _Place { phone, dock, classic, classicMany }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}f5_pick_row';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
    final lucide = await rootBundle
        .load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
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
      families
          .putIfAbsent(family, () => [])
          .add(ByteData.view(File(face.path).readAsBytesSync().buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });

  Future<ui.Image> grab(WidgetTester tester) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    return (await tester.runAsync(() => boundary.toImage()))!;
  }

  /// Before on the left, after on the right, a gap between.
  Future<void> save(WidgetTester tester, String name, ui.Image before,
      ui.Image after) async {
    await tester.runAsync(() async {
      const gap = 24.0;
      final w = before.width + gap + after.width;
      final h = before.height > after.height ? before.height : after.height;
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(Rect.fromLTWH(0, 0, w, h.toDouble()),
          Paint()..color = const Color(0xFF808080)); // design-ignore: screenshot seam
      canvas.drawImage(before, Offset.zero, Paint());
      canvas.drawImage(after, Offset(before.width + gap, 0), Paint());
      final image = await rec.endRecording().toImage(w.toInt(), h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data!.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  Widget body(_Place place) => switch (place) {
        _Place.phone => const MobileShell(),
        _Place.dock => Builder(
            builder: (context) => ColoredBox(
                color: HollowTheme.of(context).background,
                child: const HomeDashboard())),
        _Place.classic || _Place.classicMany => Builder(
            builder: (context) => ColoredBox(
              color: HollowTheme.of(context).background,
              child: const Column(
                children: [
                  RestorePickBanner(),
                  Expanded(
                    child: Row(
                      children: [
                        ServerStrip(),
                        Expanded(
                          child: HollowEmptyState(
                            glyph: LucideIcons.messageSquare,
                            title: 'Select a peer to start chatting',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      };

  Future<ui.Image> render(WidgetTester tester, _Place place, Size size,
      {required bool light, required bool after}) async {
    final restores = switch (place) {
      _Place.classic => fixtureRestores([dp.RestoreStage.points]),
      _ => fixtureRestores([dp.RestoreStage.onlyOne, dp.RestoreStage.points]),
    };
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: hollowTestOverrides(extra: [
          homeSetupProvider.overrideWith(_Setup.new),
          // Before: the build without this change showed nothing for a server
          // waiting on a pick, which is what no listed server draws.
          ...deviceProofOverrides(
              restores: after
                  ? restores
                  : const dp.Restores(serversKnown: true, servers: [])),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(body: body(place)),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    return grab(tester);
  }

  Future<void> shoot(WidgetTester tester, _Place place, Size size,
      {required bool light}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final before = await render(tester, place, size, light: light, after: false);
    final after = await render(tester, place, size, light: light, after: true);
    await save(tester, '${place.name}_${light ? 'light' : 'dark'}', before,
        after);
  }

  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    testWidgets('phone $theme',
        (t) => shoot(t, _Place.phone, const Size(390, 844), light: light));
    testWidgets('dock $theme',
        (t) => shoot(t, _Place.dock, const Size(1280, 800), light: light));
    testWidgets('classic $theme',
        (t) => shoot(t, _Place.classic, const Size(1280, 720), light: light));
    testWidgets('classic many $theme',
        (t) => shoot(t, _Place.classicMany, const Size(1280, 720),
            light: light));
  }

  testWidgets('classic narrow dark', (t) async {
    t.view.physicalSize = const Size(800, 600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final before =
        await render(t, _Place.classic, const Size(800, 600), light: false, after: false);
    final after =
        await render(t, _Place.classic, const Size(800, 600), light: false, after: true);
    await save(t, 'classic_narrow_dark', before, after);
  });

  testWidgets('phone dark, Choose opens the chooser on that server', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final row = await render(t, _Place.phone, const Size(390, 844),
        light: false, after: true);
    final choose = find.descendant(
        of: find.byKey(const ValueKey('restore-pick:test_server_002')),
        matching: find.text(kRestorePickAction));
    await t.scrollUntilVisible(choose, 200,
        scrollable: find.byType(Scrollable).first);
    await t.tap(choose);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text(kRestoreTitle), findsOneWidget);
    final chooser = await grab(t);
    await save(t, 'phone_dark_tap_to_chooser', row, chooser);
  });
}

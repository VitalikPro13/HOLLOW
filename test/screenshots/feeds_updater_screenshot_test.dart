import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/pages/about_page.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';

import '../helpers/test_app.dart';

/// Renders for the quick-patch and status v2 work: the update prompt for a
/// normal and a critical patch (Settings > About and the Home inbox), the
/// version line of a +1 build, and the banner with several live notices.
///
/// Output: $HOLLOW_SHOT_DIR/feeds_updater, else build/ui_screenshots/feeds_updater.
class _Updater extends UpdateNotifier {
  _Updater({required this.critical});
  final bool critical;

  @override
  UpdateState build() => UpdateState(
        currentVersion: '0.12.2',
        currentBuild: 1,
        lastChecked: DateTime.now().subtract(const Duration(minutes: 4)),
        manifest: VersionManifest(latest: '0.12.2', versions: [
          const VersionInfo(
              version: '0.12.2',
              date: 'October 21, 2026',
              notes: 'Platform-aware updates',
              urlWindows: 'https://h/w.zip',
              urlMacos: 'https://h/m.zip'),
          const VersionInfo(
              version: '0.12.2',
              build: 1,
              date: 'October 22, 2026',
              notes: 'Desktop voice fix',
              urlWindows: 'https://h/w1.zip',
              urlMacos: 'https://h/m1.zip'),
          VersionInfo(
              version: '0.12.2',
              build: 2,
              critical: critical,
              date: 'October 23, 2026',
              notes: 'Screen share fix',
              urlWindows: 'https://h/w2.zip',
              urlMacos: 'https://h/m2.zip'),
        ]),
      );

  @override
  Future<void> checkForUpdates({bool background = false}) async {}
}

class _Status extends StatusNotifier {
  _Status(this.fixed);
  final StatusState fixed;

  @override
  StatusState build() => fixed;
}

void main() {
  const shotKey = Key('screenshot-boundary');
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}/build/ui_screenshots/feeds_updater';

  setUpAll(() async {
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
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
    updaterPlatformOverride = 'macos';
  });
  tearDownAll(() => updaterPlatformOverride = null);

  Future<void> shoot(WidgetTester tester, String name, Widget child,
      {required List<Override> extra,
      Size size = const Size(900, 760),
      bool light = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: extra),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(body: child),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$outDir/$name.png')..parent.createSync(recursive: true);
      file.writeAsBytesSync(data!.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    for (final critical in [false, true]) {
      final kind = critical ? 'critical' : 'normal';
      testWidgets('about updates, $kind, $theme', (tester) async {
        await shoot(
            tester,
            'about_${kind}_$theme',
            const SingleChildScrollView(child: AboutSettingsPage()),
            extra: [
              updaterProvider.overrideWith(() => _Updater(critical: critical))
            ],
            light: light);
      });

      testWidgets('home inbox, $kind, $theme', (tester) async {
        await shoot(
            tester,
            'inbox_${kind}_$theme',
            const Padding(
              padding: EdgeInsets.all(24),
              child: SingleChildScrollView(child: HomeAttention()),
            ),
            extra: [
              updaterProvider.overrideWith(() => _Updater(critical: critical))
            ],
            size: const Size(520, 220),
            light: light);
      });
    }

    testWidgets('banner with several notices, $theme', (tester) async {
      final expires = DateTime.utc(2030);
      await shoot(
          tester,
          'banner_several_$theme',
          const Column(children: [SystemStatusBanner(), Spacer()]),
          extra: [
            statusProvider.overrideWith(() => _Status(StatusState(
                  hasFetched: true,
                  dismissedIds: const {'outage'},
                  notices: [
                    SystemStatus(
                        id: 'note',
                        level: StatusLevel.info,
                        title: 'New stickers are in the shop',
                        expires: expires),
                    SystemStatus(
                        id: 'maint',
                        level: StatusLevel.maintenance,
                        title: 'Relay maintenance tonight',
                        message: 'Calls may drop for a minute or two.',
                        until: DateTime.now()
                            .toUtc()
                            .add(const Duration(hours: 3)),
                        untilLabel: 'Starts in',
                        expires: expires),
                    SystemStatus(
                        id: 'outage',
                        level: StatusLevel.critical,
                        title: 'Dismissed outage notice',
                        expires: expires),
                  ],
                )))
          ],
          size: const Size(900, 120),
          light: light);
    });
  }

  // ONE image per theme: the same update as every build shows it (left) and
  // marked critical (right); Settings > About above the Home inbox.
  for (final theme in ['dark', 'light']) {
    testWidgets('before and after, $theme', (tester) async {
      await tester.runAsync(() async {
        Future<ui.Image> load(String name) async {
          final codec = await ui.instantiateImageCodec(
              File('$outDir/$name.png').readAsBytesSync());
          return (await codec.getNextFrame()).image;
        }

        final cells = [
          [await load('about_normal_$theme'), await load('about_critical_$theme')],
          [await load('inbox_normal_$theme'), await load('inbox_critical_$theme')],
        ];
        const aboutCrop = 260.0;
        const gap = 16.0;
        final colW = cells[0][0].width.toDouble();
        final height = aboutCrop + gap + cells[1][0].height;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(Rect.fromLTWH(0, 0, colW * 2 + gap, height),
            Paint()..color = theme == 'dark' ? const Color(0xFF000000) : const Color(0xFFFFFFFF)); // design-ignore: test image backdrop
        for (var col = 0; col < 2; col++) {
          final x = col * (colW + gap);
          canvas.drawImageRect(cells[0][col], const Rect.fromLTWH(0, 0, 900, aboutCrop),
              Rect.fromLTWH(x, 0, colW, aboutCrop), Paint());
          canvas.drawImage(cells[1][col], Offset(x, aboutCrop + gap), Paint());
        }
        final out = await recorder
            .endRecording()
            .toImage((colW * 2 + gap).round(), height.round());
        final data = await out.toByteData(format: ui.ImageByteFormat.png);
        File('$outDir/before_after_$theme.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
        debugPrint('[screenshot] wrote $outDir/before_after_$theme.png');
      });
    });
  }
}

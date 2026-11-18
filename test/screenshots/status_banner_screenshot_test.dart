import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

/// Renders the system status banner (0.14.1 redesign) with the live App Store
/// notice: a long warning with a days-long countdown and a link, collapsed and
/// expanded, at desktop and phone widths, dark and light.
///
/// Output: $HOLLOW_SHOT_DIR/status_banner, else build/ui_screenshots/status_banner.
/// With HOLLOW_SHOT_BEFORE pointing at an earlier run's folder, the last test
/// also writes before|after sheets.
class _Status extends StatusNotifier {
  _Status(this.fixed);
  final StatusState fixed;

  @override
  StatusState build() => fixed;
}

const _appStoreMessage =
    'Hollow for iPhone and iPad is now on the App Store, and the TestFlight '
    'beta ends on November 22. The App Store version is the same app. If you '
    'use TestFlight, open the App Store page and tap Install, and your data '
    'stays. Do not delete Hollow first. Then stop testing Hollow in the '
    'TestFlight app.';

StatusState _appStore() => StatusState(hasFetched: true, notices: [
      SystemStatus(
        id: 'appstore',
        level: StatusLevel.warning,
        title: 'Hollow is now on the App Store',
        message: _appStoreMessage,
        until: DateTime.now()
            .toUtc()
            .add(const Duration(days: 5, hours: 10, minutes: 36, seconds: 30)),
        untilLabel: 'TestFlight ends in',
        link: 'https://apps.apple.com/app/id6777748033',
        linkLabel: 'Open App Store',
        expires: DateTime.utc(2099),
      ),
    ]);

StatusState _maintenance() => StatusState(hasFetched: true, notices: [
      SystemStatus(
        id: 'maint',
        level: StatusLevel.maintenance,
        title: 'Relay maintenance tonight',
        message: 'Calls may drop for a minute or two.',
        until: DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 14, seconds: 30)),
        untilLabel: 'Starts in',
        expires: DateTime.utc(2099),
      ),
    ]);

void main() {
  const shotKey = Key('screenshot-boundary');
  final root = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}/build/ui_screenshots';
  final outDir = '$root/status_banner';

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
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required StatusState state,
    required Size size,
    required bool phone,
    required bool light,
    required bool expand,
  }) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        statusProvider.overrideWith(() => _Status(state)),
      ]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(
            body: phone
                ? const Column(children: [
                    Spacer(),
                    SystemStatusBanner(anchor: StatusBannerAnchor.bottom),
                  ])
                : const Column(children: [SystemStatusBanner(), Spacer()]),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    if (expand) {
      await tester.tap(find.byIcon(LucideIcons.chevronDown));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$outDir/$name.png')..parent.createSync(recursive: true);
      file.writeAsBytesSync(data!.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  final names = <String>[];
  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    for (final phone in [false, true]) {
      final form = phone ? 'phone' : 'desktop';
      final size = phone ? const Size(390, 420) : const Size(1280, 200);
      for (final expand in [false, true]) {
        final open = expand ? 'open' : 'shut';
        for (final fixture in ['appstore', 'maint']) {
          final name = '${fixture}_${form}_${open}_$theme';
          names.add(name);
          testWidgets(name, (tester) async {
            await shoot(tester, name,
                state: fixture == 'appstore' ? _appStore() : _maintenance(),
                size: size,
                phone: phone,
                light: light,
                expand: expand);
          });
        }
      }
    }
  }

  // ONE image per (form, theme): before on the left, after on the right, the
  // four states stacked.
  final before = Platform.environment['HOLLOW_SHOT_BEFORE'];
  if (before != null) {
    for (final form in ['desktop', 'phone']) {
      for (final theme in ['dark', 'light']) {
        testWidgets('before and after, $form, $theme', (tester) async {
          await tester.runAsync(() async {
            Future<ui.Image> load(String dir, String name) async {
              final codec = await ui.instantiateImageCodec(
                  File('$dir/$name.png').readAsBytesSync());
              return (await codec.getNextFrame()).image;
            }

            final rows = [
              for (final open in ['shut', 'open'])
                for (final fixture in ['appstore', 'maint'])
                  '${fixture}_${form}_${open}_$theme',
            ];
            const gap = 24.0;
            final left = [for (final r in rows) await load(before, r)];
            final right = [for (final r in rows) await load(outDir, r)];
            final colW = left.first.width.toDouble();
            final rowH = left.first.height.toDouble();
            final w = colW * 2 + gap;
            final h = rows.length * rowH + (rows.length - 1) * gap;
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            canvas.drawRect(
                Rect.fromLTWH(0, 0, w, h),
                Paint()
                  ..color = const Color(0xFFFF00FF)); // design-ignore: test image backdrop, a seam no theme uses
            for (var i = 0; i < rows.length; i++) {
              final y = i * (rowH + gap);
              canvas.drawImage(left[i], Offset(0, y), Paint());
              canvas.drawImage(right[i], Offset(colW + gap, y), Paint());
            }
            final out =
                await recorder.endRecording().toImage(w.round(), h.round());
            final data = await out.toByteData(format: ui.ImageByteFormat.png);
            final file = File('$outDir/before_after_${form}_$theme.png');
            file.writeAsBytesSync(data!.buffer.asUint8List());
            debugPrint('[screenshot] wrote ${file.path}');
          });
        });
      }
    }
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/pages/devices_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/test_app.dart';

/// The confirm that guards approving a device a phrase recovery cut off, on the
/// Devices page at desktop and phone widths, dark and light.
/// Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/f5_approve_confirm.
class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

const _asker = '12D3KooWT3CzWvzTVyNsXZYEvzRuKP88qbEanuVDYaiMYxppX7AX';

roster_api.RosterStatus _status(String cutOff) => roster_api.RosterStatus(
      member: true,
      protected: true,
      backupWait: false,
      devices: [
        const roster_api.RosterDevice(devicePeerId: 'me', state: 'member', thisDevice: true, added: []),
        roster_api.RosterDevice(
          devicePeerId: _asker,
          state: 'pending',
          thisDevice: false,
          added: const [],
          firstSeenMs: 1_795_000_060_000,
          cutOffAtMs: 1_795_000_000_000,
          cutOff: cutOff,
        ),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}f5_approve_confirm';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
    final lucide = await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(Future.value(lucide))).load();
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
      families.putIfAbsent(family, () => []).add(ByteData.view(File(face.path).readAsBytesSync().buffer));
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
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
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

  Future<void> shoot(WidgetTester tester, String name,
      {required double width, required double height, required String cutOff, bool light = false}) async {
    final touch = width < 600;
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: ProviderScope(
        overrides: hollowTestOverrides(extra: [
          myDevicesProvider.overrideWithValue(const [
            MyDevice(peerId: 'me', isThisDevice: true, online: true, label: 'Desktop'),
          ]),
          rosterStatusProvider.overrideWith((ref) async => _status(cutOff)),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(builder: (context) {
              return ColoredBox(
                color: HollowTheme.of(context).background,
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(touch ? HollowSpacing.lg : HollowSpacing.xl),
                  child: SettingsDensity(touch: touch, child: const DevicesSettingsPage()),
                ),
              );
            }),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await capture(tester, '${name}_row');
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Let this device back in?'), findsOneWidget);
    await capture(tester, '${name}_dialog');
  }

  testWidgets('desktop, dark, a copy', (tester) => shoot(tester, 'desktop_dark_maybe', width: 1280, height: 720, cutOff: 'maybe'));
  testWidgets('desktop, light, ours', (tester) => shoot(tester, 'desktop_light_ours', width: 1280, height: 720, cutOff: 'ours', light: true));
  testWidgets('phone 375, dark, a copy', (tester) => shoot(tester, 'phone375_dark_maybe', width: 375, height: 812, cutOff: 'maybe'));
  testWidgets('phone 320, light, a copy', (tester) => shoot(tester, 'phone320_light_maybe', width: 320, height: 640, cutOff: 'maybe', light: true));
}

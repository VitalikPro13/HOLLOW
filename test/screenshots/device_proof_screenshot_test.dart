import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/server_recovery_notices.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/dialogs/restore_chooser.dart';
import 'package:hollow/src/ui/server_settings/pages/lost_devices_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/device_proof_fixtures.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// The device-proof screens BEFORE (what the node answers while track C1's
/// bodies are stubs) beside AFTER (the fixtures), one image per screen, dark
/// and light, desktop and phone. Output: build/ui_screenshots/device_proof.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}device_proof';

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

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
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

  /// BEFORE left, AFTER right, each in its own provider scope.
  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Widget Function(bool after) pane,
    required List<Override> Function(bool after) overrides,
    required double paneWidth,
    required double height,
    bool light = false,
    bool touch = false,
  }) async {
    final size = Size(paneWidth * 2 + 1, height);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = light ? HollowThemeData.light() : HollowThemeData.dark();
    Widget side(bool after) => SizedBox(
          width: paneWidth,
          child: ProviderScope(
            overrides: hollowTestOverrides(extra: overrides(after)),
            child: Builder(builder: (context) {
              final hollow = HollowTheme.of(context);
              return ColoredBox(
                color: hollow.background,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: hollow.surface,
                      padding: const EdgeInsets.all(HollowSpacing.sm),
                      child: Text(after ? 'After' : 'Before',
                          style: HollowTypography.caption
                              .copyWith(color: hollow.textSecondary)),
                    ),
                    Expanded(
                      child: SettingsDensity(touch: touch, child: pane(after)),
                    ),
                  ],
                ),
              );
            }),
          ),
        );
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                side(false),
                SizedBox(
                    width: 1,
                    child: ColoredBox(color: HollowTheme.of(context).border)),
                side(true),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await capture(tester, name);
  }

  /// A stand-in for a server's chat column: header, the strips, the canvas.
  Widget chat(bool touch) => Builder(builder: (context) {
        final hollow = HollowTheme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 52,
              color: hollow.surface,
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
              alignment: AlignmentDirectional.centerStart,
              child: Text('# general',
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.textPrimary)),
            ),
            const HollowDivider(),
            ServerRecoveryNotices(serverId: kServerId1, touch: touch),
            Expanded(child: ColoredBox(color: hollow.background)),
          ],
        );
      });

  final chatCases = {
    'stepped_back': const dp.ServerRecovery(steppedBack: true),
    'shell': const dp.ServerRecovery(steppedBack: true, removedBy: kTomas),
  };
  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    for (final e in chatCases.entries) {
      testWidgets('chat ${e.key} $theme', (tester) async {
        await shoot(tester, 'chat_${e.key}_desktop_$theme',
            paneWidth: 800,
            height: 260,
            light: light,
            pane: (_) => chat(false),
            overrides: (after) => deviceProofOverrides(
                recovery: after ? e.value : const dp.ServerRecovery(steppedBack: false)));
      });
    }
    testWidgets('chat owner notice $theme', (tester) async {
      await shoot(tester, 'chat_owner_notice_desktop_$theme',
          paneWidth: 800,
          height: 260,
          light: light,
          pane: (_) => chat(false),
          overrides: (after) =>
              deviceProofOverrides(reviews: after ? fixtureReviews : null));
    });
  }
  for (final e in chatCases.entries) {
    testWidgets('chat ${e.key} phone', (tester) async {
      await shoot(tester, 'chat_${e.key}_phone_dark',
          paneWidth: 375,
          height: 340,
          touch: true,
          pane: (_) => chat(true),
          overrides: (after) => deviceProofOverrides(
              recovery: after ? e.value : const dp.ServerRecovery(steppedBack: false)));
    });
  }
  testWidgets('chat owner notice phone', (tester) async {
    await shoot(tester, 'chat_owner_notice_phone_dark',
        paneWidth: 375,
        height: 340,
        touch: true,
        pane: (_) => chat(true),
        overrides: (after) =>
            deviceProofOverrides(reviews: after ? fixtureReviews : null));
  });

  Widget page(bool touch) => SingleChildScrollView(
        padding: EdgeInsets.all(touch ? HollowSpacing.lg : HollowSpacing.xl),
        child: const LostDevicesPage(serverId: kServerId1),
      );

  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    testWidgets('review page $theme', (tester) async {
      await shoot(tester, 'review_desktop_$theme',
          paneWidth: 900,
          height: 2000,
          light: light,
          pane: (_) => page(false),
          overrides: (after) =>
              deviceProofOverrides(reviews: after ? fixtureReviews : null));
    });
  }
  testWidgets('review page phone', (tester) async {
    await shoot(tester, 'review_phone_dark',
        paneWidth: 375,
        height: 3600,
        touch: true,
        pane: (_) => page(true),
        overrides: (after) =>
            deviceProofOverrides(reviews: after ? fixtureReviews : null));
  });

  final chooserCases = {
    'pick': [dp.RestoreStage.pick],
    'points': [dp.RestoreStage.points],
    'only_one_and_waits': [
      dp.RestoreStage.onlyOne,
      dp.RestoreStage.waiting,
    ],
    'checking_nobody_done': [
      dp.RestoreStage.checking,
      dp.RestoreStage.nobodyReachable,
      dp.RestoreStage.done,
    ],
  };
  Widget chooser() => const Center(child: RestoreChooserDialog());
  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    for (final e in chooserCases.entries) {
      testWidgets('chooser ${e.key} $theme', (tester) async {
        await shoot(tester, 'chooser_${e.key}_desktop_$theme',
            paneWidth: 800,
            height: 900,
            light: light,
            pane: (_) => chooser(),
            overrides: (after) => deviceProofOverrides(
                restores: after ? fixtureRestores(e.value) : null));
      });
    }
  }
  for (final e in chooserCases.entries) {
    testWidgets('chooser ${e.key} phone', (tester) async {
      await shoot(tester, 'chooser_${e.key}_phone_dark',
          paneWidth: 375,
          height: 812,
          touch: true,
          pane: (_) => chooser(),
          overrides: (after) => deviceProofOverrides(
              restores: after ? fixtureRestores(e.value) : null));
    });
  }
}

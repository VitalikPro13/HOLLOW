import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/archive_conversation.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/mobile/mobile_archive_page.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/settings/settings_place.dart';
import 'package:hollow/src/ui/components/wallpaper_backdrop.dart';

import '../helpers/test_app.dart';

/// #144 by eye: Settings beside a chat with a hovered message over a light,
/// busy wallpaper at Darken 40, 70 and 100, plus the two phone actions that
/// gained a label.
///
/// `HOLLOW_144_MODE=before` composes the screen the way 0.14.0 did (the theme
/// made see-through app-wide, the picture under the shell with no dim of its
/// own; on a phone a scrim of the Darken value). Run it against the base
/// `lib/` for a true before. `after` (the default) uses `WallpaperBackdrop`.
/// Output: `$HOLLOW_SHOT_DIR/wallpaper_144/<mode>/`.
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

class _Wallpaper extends BackgroundNotifier {
  _Wallpaper(this.bytes, this.darken);
  final Uint8List bytes;
  final double darken;
  @override
  BackgroundState build() =>
      BackgroundState(imageBytes: bytes, panelOpacity: darken);
}

class _NoReduce extends ReduceTransparencyNotifier {
  @override
  Future<bool> build() async => false;
}

class _Conference extends ConferenceNotifier {
  @override
  ConferenceState build() => const ConferenceState(roomsLoaded: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final mode = Platform.environment['HOLLOW_144_MODE'] ?? 'after';
  final before = mode == 'before';
  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}/build/ui_screenshots'}/wallpaper_144/$mode';
  late Uint8List wallpaper;

  setUpAll(() async {
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

  /// Light and busy like the report: pale ground, white stripes, a dark red
  /// shape and grey blocks (the same picture as the fleet's seed_wallpaper).
  Future<Uint8List> busyWallpaper(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        const w = 1600.0, h = 1000.0;
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        ui.Paint fill(int argb) => ui.Paint()..color = ui.Color(argb);
        canvas.drawRect(const ui.Rect.fromLTWH(0, 0, w, h), fill(0xFFEDE3D2));
        for (var i = 0; i < 16; i++) {
          canvas.drawRect(
              ui.Rect.fromLTWH(i * 100.0, 0, 40, h), fill(0xFFFFFFFF));
        }
        canvas.drawCircle(const ui.Offset(900, 450), 330, fill(0xFF8E1B1B));
        for (var i = 0; i < 12; i++) {
          canvas.drawRect(
              ui.Rect.fromLTWH((i * 137) % 1500.0, (i * 89) % 900.0, 160, 110),
              fill(i.isEven ? 0xFF9A9A9A : 0xFFC8B27A));
        }
        final image =
            await recorder.endRecording().toImage(w.toInt(), h.toInt());
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      }))!;

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
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

  /// 0.14.0's app-wide see-through theme (app.dart before #144).
  ThemeData beforeTheme(double darken) {
    final data = HollowThemeData.dark();
    final hollow = data.extension<HollowTheme>()!;
    final base = darken.clamp(0.3, 0.95);
    return data.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      extensions: [
        hollow.copyWith(
          background: hollow.background
              .withValues(alpha: (base * 0.65).clamp(0.15, 0.8)),
          surface:
              hollow.surface.withValues(alpha: (base * 0.85).clamp(0.4, 0.92)),
          elevated: hollow.elevated
              .withValues(alpha: (base * 0.95).clamp(0.5, 0.95)),
        ),
      ],
    );
  }

  /// The picture under [child] as each version painted it.
  Widget backdrop(Widget child, double darken, {required bool phone}) {
    if (!before) return WallpaperBackdrop(child: child);
    return Builder(builder: (context) {
      final hollow = HollowTheme.of(context);
      return Stack(children: [
        Positioned.fill(
          child: ColoredBox(
            color: HollowColors.mediaBlack,
            child: Image.memory(wallpaper, fit: BoxFit.cover),
          ),
        ),
        if (phone)
          Positioned.fill(
            child: ColoredBox(
                color: hollow.background
                    .withValues(alpha: darken.clamp(0.0, 0.92))),
          ),
        child,
      ]);
    });
  }

  Future<ProviderContainer> pump(WidgetTester tester,
      {required Size size,
      required Widget home,
      double darken = 1.0,
      bool wallpaperTheme = true,
      List<Override> extra = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        backgroundProvider.overrideWith(() => _Wallpaper(wallpaper, darken)),
        reduceTransparencyProvider.overrideWith(_NoReduce.new),
        ...extra,
      ]),
    );
    addTearDown(container.dispose);
    openSettings(container.read, category: SettingsCategory.appearance);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: before && wallpaperTheme
              ? beforeTheme(darken)
              : HollowThemeData.dark(),
          home: home,
        ),
      ),
    ));
    // Images decode on real time only.
    await tester.runAsync(() async {
      await precacheImage(
          MemoryImage(wallpaper), tester.element(find.byKey(shotKey)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    return container;
  }

  for (final darken in [1.0, 0.7, 0.4]) {
    final pct = (darken * 100).round();
    testWidgets('desktop: Settings beside a chat at Darken $pct',
        (tester) async {
      wallpaper = await busyWallpaper(tester);
      await pump(
        tester,
        size: const Size(1440, 720),
        darken: darken,
        home: backdrop(
          const Scaffold(
            backgroundColor: Colors.transparent,
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 900, child: SettingsPlace()),
                Expanded(child: _Chat()),
              ],
            ),
          ),
          darken,
          phone: false,
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text(_lines[3].$2)));
      await tester.pump(const Duration(milliseconds: 400));
      await capture(tester, 'desktop_$pct');
    }, variant: _desktop);

    testWidgets('phone: the Settings tab at Darken $pct', (tester) async {
      wallpaper = await busyWallpaper(tester);
      final c = await pump(
        tester,
        size: const Size(390, 844),
        darken: darken,
        home: backdrop(
          const Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(child: MobileSettingsTab()),
          ),
          darken,
          phone: true,
        ),
      );
      await capture(tester, 'phone_settings_$pct');
      // Outlives the relay card's poll.
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      await tester.pump(const Duration(minutes: 2));
    }, variant: _phone);
  }

  testWidgets('phone: Conferences header', (tester) async {
    wallpaper = await busyWallpaper(tester);
    await pump(tester,
        size: const Size(390, 500),
        home: const MobileConferencesRoute(),
        wallpaperTheme: false,
        extra: [conferenceProvider.overrideWith(() => _Conference())]);
    await capture(tester, 'phone_conferences');
  }, variant: _phone);

  testWidgets('phone: Archive server group', (tester) async {
    wallpaper = await busyWallpaper(tester);
    const group = ArchiveChannelGroup(
      serverId: 's1',
      serverName: 'Night shift',
      channels: [
        ArchiveChannelEntry(
            serverId: 's1',
            serverName: 'Night shift',
            channelId: 'c1',
            channelName: 'general',
            messageCount: 12),
        ArchiveChannelEntry(
            serverId: 's1',
            serverName: 'Night shift',
            channelId: 'c2',
            channelName: 'mixdowns',
            messageCount: 4),
      ],
    );
    await pump(tester,
        size: const Size(390, 500),
        home: const MobileArchivePage(),
        wallpaperTheme: false,
        extra: [
          archiveDmListProvider.overrideWith((ref) async => const []),
          archiveChannelListProvider.overrideWith((ref) async => const [group]),
        ]);
    await tester.pump(const Duration(milliseconds: 300));
    await capture(tester, 'phone_archive');
  }, variant: _phone);
}

const _lines = [
  ('Nhox', 'did the stems export finish'),
  ('Rong', 'almost, uploading them to the server now'),
  ('Nhox', 'the pad on track 4 needs a slower attack, it clicks on the downbeat'),
  ('Rong', 'sending the bounce in a minute'),
  ('Nhox', 'sounds good'),
];

/// A chat the way the shell nests it: the pane's canvas, then the list's.
class _Chat extends StatelessWidget {
  const _Chat();
  @override
  Widget build(BuildContext context) {
        final hollow = HollowTheme.of(context);
        TextStyle s(Color c) => HollowTypography.body.copyWith(color: c);
        return ColoredBox(
          color: hollow.background,
          child: MessageActionBarScope(
            child: ColoredBox(
              color: hollow.background,
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 16),
                children: [
                  for (final (i, (who, text)) in _lines.indexed)
                    MessageHoverWrapper(
                      key: ValueKey(i),
                      isMe: false,
                      messageId: 'm$i',
                      currentText: text,
                      onReply: () {},
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(who, style: s(hollow.accentText)),
                            Text(text, style: s(hollow.textPrimary)),
                            Text('15:1$i',
                                style: HollowTypography.caption
                                    .copyWith(color: hollow.textTertiary)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      }
}

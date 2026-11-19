// Issue #144: a wallpaper wears ONE dim, the Darken the user chose, under
// every canvas. Canvases nested in each other (the chat inside its pane) or side
// by side (Settings beside the chat) no longer stack their own dims, so
// Settings is as dark as the chat and a hovered message stays a small lift.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/wallpaper_backdrop.dart';

import '../helpers/test_app.dart';

// A 1x1 PNG: the backdrop only needs bytes to call it a wallpaper.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xA7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _Wallpaper extends BackgroundNotifier {
  final double darken;
  final bool image;
  _Wallpaper(this.darken, {this.image = true});
  @override
  BackgroundState build() =>
      BackgroundState(imageBytes: image ? _png : null, panelOpacity: darken);
}

class _ReduceTransparency extends ReduceTransparencyNotifier {
  final bool on;
  _ReduceTransparency(this.on);
  @override
  Future<bool> build() async => on;
}

class _Toggle extends BackgroundNotifier {
  @override
  BackgroundState build() => const BackgroundState();
  void set(bool on) =>
      state = BackgroundState(imageBytes: on ? _png : null, panelOpacity: 1);
}

class _MountCounter extends StatefulWidget {
  final VoidCallback onMount;
  const _MountCounter(this.onMount);
  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

const _probe = Key('probe');

/// Pumps [WallpaperBackdrop] around a canvas inside a canvas, the shape of
/// the chat (shell pane + message list), and returns the theme the inner
/// canvas reads.
Future<HollowTheme> _pump(WidgetTester tester,
    {double darken = 1.0,
    bool image = true,
    bool reduce = false,
    Widget Function(Widget)? wrapInner}) async {
  late HollowTheme seen;
  // A fresh scope each time: a re-pumped scope keeps its first notifier.
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: hollowTestOverrides(extra: [
      backgroundProvider.overrideWith(() => _Wallpaper(darken, image: image)),
      reduceTransparencyProvider
          .overrideWith(() => _ReduceTransparency(reduce)),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: WallpaperBackdrop(
        child: (wrapInner ?? (w) => w)(Builder(builder: (context) {
          seen = HollowTheme.of(context);
          return ColoredBox(
            color: seen.background,
            child: ColoredBox(
              key: _probe,
              color: seen.background,
              child: const SizedBox.expand(),
            ),
          );
        })),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return seen;
}

/// The one dim the backdrop paints over the picture.
Color? _dim(WidgetTester tester) {
  final boxes = tester
      .widgetList<ColoredBox>(find.byKey(WallpaperBackdrop.dimKey))
      .toList();
  return boxes.isEmpty ? null : boxes.single.color;
}

/// [over] laid on a flat picture of [picture].
Color _on(Color over, Color picture) => Color.alphaBlend(over, picture);

const _white = Color(0xFFFFFFFF);
const _black = Color(0xFF000000);

final _themes = [
  ('dark', HollowThemeData.dark().extension<HollowTheme>()!),
  ('light', HollowThemeData.light().extension<HollowTheme>()!),
];

void main() {
  group('one dim under every canvas', () {
    testWidgets('a canvas inside a canvas adds no dim of its own',
        (tester) async {
      final hollow = await _pump(tester);
      expect(hollow.background.a, 0,
          reason: 'a see-through canvas stacks; the dim lives in the backdrop');
      expect(tester.widget<ColoredBox>(find.byKey(_probe)).color.a, 0);
      expect(_dim(tester), isNotNull);
    });

    testWidgets('a backdrop inside a backdrop paints nothing more',
        (tester) async {
      await _pump(tester, wrapInner: (w) => WallpaperBackdrop(child: w));
      expect(find.byKey(WallpaperBackdrop.dimKey), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('every Darken step is darker',
        (tester) async {
      final alphas = <double>[];
      for (final d in [0.4, 0.5, 0.7, 0.9, 0.95, 1.0]) {
        await _pump(tester, darken: d);
        alphas.add(_dim(tester)!.a);
      }
      for (var i = 1; i < alphas.length; i++) {
        expect(alphas[i], greaterThan(alphas[i - 1]),
            reason: 'Darken ${alphas[i]} must be darker than the step before');
      }
    });

    testWidgets('setting or clearing a wallpaper never remounts the app',
        (tester) async {
      // The shell starts the node in initState: a remount restarts it.
      final notifier = _Toggle();
      var mounts = 0;
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          backgroundProvider.overrideWith(() => notifier),
          reduceTransparencyProvider
              .overrideWith(() => _ReduceTransparency(false)),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: WallpaperBackdrop(child: _MountCounter(() => mounts++)),
        ),
      ));
      expect(mounts, 1);
      notifier.set(true);
      await tester.pump();
      expect(_dim(tester), isNotNull);
      notifier.set(false);
      await tester.pump();
      notifier.set(true);
      await tester.pump();
      expect(mounts, 1, reason: 'the child kept its state through every change');
    });

    testWidgets('no wallpaper leaves the theme and the tree alone',
        (tester) async {
      final hollow = await _pump(tester, image: false);
      expect(hollow.background.a, 1);
      expect(_dim(tester), isNull);
    });

    testWidgets('Reduce transparency covers the picture with the opaque canvas',
        (tester) async {
      final hollow = await _pump(tester, reduce: true);
      expect(hollow.background.a, 1);
      expect(_dim(tester), isNull);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('routes above the wallpapered one keep an opaque canvas',
        (tester) async {
      await _pump(tester);
      final outside =
          HollowTheme.of(tester.element(find.byType(WallpaperBackdrop)));
      expect(outside.background.a, 1,
          reason: 'a pushed page has no picture behind it');
    });

    testWidgets('a sheet opened over the wallpaper is opaque', (tester) async {
      await _pump(tester);
      late HollowTheme inSheet;
      showHollowSheet<void>(
        context: tester.element(find.byKey(_probe)),
        builder: (context) {
          inSheet = HollowTheme.of(context);
          return const SizedBox(height: 120);
        },
      );
      await tester.pumpAndSettle();
      expect(inSheet.background.a, 1,
          reason: 'the sheet floats with no picture behind it');
      expect(inSheet.elevated.a, 1);
    });
  });

  group('readable over any picture', () {
    for (final (name, hollow) in _themes) {
      for (final (pictureName, picture) in [
        ('white', _white),
        ('black', _black),
      ]) {
        Color canvas(double darken) => _on(
            hollow.opaqueBackground
                .withValues(alpha: HollowTheme.wallpaperDim(darken)),
            picture);
        test('$name theme over a $pictureName picture: muted tiers clear '
            '4.5:1 at full Darken, primary text at the lowest', () {
          for (final ink in [hollow.textSecondary, hollow.textTertiary]) {
            expect(Contrast.ratio(ink, canvas(1.0)), greaterThanOrEqualTo(4.5));
          }
          expect(Contrast.ratio(hollow.textPrimary, canvas(0.4)),
              greaterThanOrEqualTo(4.5));
        });
      }
    }
  });

  group('a hovered message over a wallpaper', () {
    testWidgets('is a small lift on any picture, never a slab',
        (tester) async {
      for (final d in [0.4, 0.7, 1.0]) {
        final hollow = await _pump(tester, darken: d);
        final dim = _dim(tester)!;
        for (final picture in [_white, _black, const Color(0xFF8B1A1A)]) {
          final canvas = _on(dim, picture);
          final hovered = _on(hollow.rowHover, canvas);
          final step = Contrast.ratio(hovered, canvas);
          expect(step, greaterThan(1.02), reason: 'the hover still shows');
          expect(step, lessThan(1.25),
              reason: 'Darken $d over $picture: the hover is a state layer');
          // A lift in dark: the hover never darkens the row it marks.
          expect(Contrast.relativeLuminance(hovered),
              greaterThan(Contrast.relativeLuminance(canvas)));
        }
      }
    });

    test('an opaque canvas keeps the half step toward raised', () {
      final hollow = _themes.first.$2;
      expect(hollow.rowHover,
          Color.lerp(hollow.background, hollow.elevated, 0.5));
    });
  });
}

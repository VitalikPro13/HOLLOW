import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind, kLongPressTimeout, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/call/speaking_ring.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/expression_preview.dart';
import 'package:hollow/src/ui/components/name_text.dart';
import 'package:hollow/src/ui/settings/name_color_editor.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../helpers/test_app.dart';

/// Render sheets for #140, #158 and #159 (real fonts, both themes), for when
/// the fleet cannot run. #140's and #158's BEFORE columns recompute the
/// 0.14.2 rule from its own formula (4.5:1 floor; thumb = visible rows / all
/// rows); #159's BEFORE is what a hold showed then: nothing.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shotKey = Key('screenshot-boundary');
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}/build/ui_screenshots';

  setUpAll(() async {
    final onest = FontLoader('Onest');
    for (final w in [400, 500, 600]) {
      onest.addFont(rootBundle.load('assets/fonts/Onest-$w.ttf'));
    }
    await onest.load();
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(rootBundle
              .load('packages/lucide_icons_flutter/assets/lucide.ttf')))
        .load();
    final mono = FontLoader('Geist Mono');
    mono.addFont(rootBundle.load('assets/fonts/GeistMono-400.ttf'));
    try {
      await mono.load();
    } catch (_) {/* mono labels fall back */}
    try {
      final emoji = File('/System/Library/Fonts/Apple Color Emoji.ttc');
      if (emoji.existsSync()) {
        final bytes = emoji.readAsBytesSync();
        await (FontLoader('Apple Color Emoji')
              ..addFont(Future.value(ByteData.view(bytes.buffer))))
            .load();
      }
    } catch (_) {/* no colour emoji on this machine */}
  });

  Future<void> save(WidgetTester tester, String name, {double ratio = 2}) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    final image = await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: ratio);
      return img.toByteData(format: ui.ImageByteFormat.png);
    });
    Directory(outDir).createSync(recursive: true);
    File('$outDir/$name.png').writeAsBytesSync(image!.buffer.asUint8List());
  }

  String hex(Color c) =>
      '#${(c.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// One labelled BEFORE | AFTER sheet from frames already written.
  Future<void> compose(WidgetTester tester, String name,
      List<(String, String, bool)> frames) async {
    final hollow = HollowTheme.dark();
    final images = <ui.Image>[];
    for (final (_, file, _) in frames) {
      final bytes = File('$outDir/$file.png').readAsBytesSync();
      final image = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bytes);
        return (await codec.getNextFrame()).image;
      });
      images.add(image!);
    }
    const scale = 1.5;
    final w = images.map((i) => i.width / scale).reduce((a, b) => a + b) +
        HollowSpacing.lg * (frames.length + 2);
    final h = images.map((i) => i.height / scale).reduce((a, b) => a > b ? a : b) +
        80;
    tester.view.physicalSize = Size(w, h);
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: const Color(0xff3c3c46), // design-ignore: comparison sheet backdrop
          child: Padding(
            padding: const EdgeInsets.all(HollowSpacing.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < frames.length; i++) ...[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(frames[i].$1,
                          style: HollowTypography.label.copyWith(
                              color: frames[i].$3
                                  ? hollow.accentText
                                  : hollow.textPrimary)),
                      const SizedBox(height: HollowSpacing.sm),
                      RawImage(
                        image: images[i],
                        width: images[i].width / scale,
                        height: images[i].height / scale,
                      ),
                    ],
                  ),
                  const SizedBox(width: HollowSpacing.lg),
                ],
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await save(tester, name, ratio: 1);
  }

  // ---------------------------------------------------------------- #140
  Widget colourSheet(HollowTheme hollow, String title) {
    final surfaces = [
      hollow.surface, hollow.background, hollow.elevated, hollow.overlay,
      hollow.hover,
    ];
    Color before(Color pick) =>
        Contrast.ensureContrastOnAll(pick, surfaces, targetRatio: 4.5);
    final label = HollowTypography.caption.copyWith(color: hollow.textTertiary);
    final name = HollowTypography.subheading;
    Widget head(String t, double w) =>
        SizedBox(width: w, child: Text(t, style: label));
    Widget ring(Color c) => SpeakingRing(
          speaking: true,
          color: c,
          radius: 10,
          stroke: 3,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
    Widget row(String what, Color pick) {
      final b = before(pick);
      final field = nameColorField([pick]);
      final a = namePaintFor('x', hollow, field: field, self: true).color;
      final aRing = callRingColor(hollow, isSelf: true, master: 'x', field: field);
      return Padding(
        padding: const EdgeInsets.only(bottom: HollowSpacing.md),
        child: Row(children: [
          SizedBox(
              width: 150,
              child: Text(what,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary))),
          SizedBox(
            width: 110,
            child: Row(children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: pick,
                  borderRadius: BorderRadius.circular(hollow.radiusXs),
                  border: Border.all(color: hollow.border),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Text(hex(pick), style: label),
            ]),
          ),
          SizedBox(
              width: 150,
              child: NameText('RongYao', paint: NamePaint([b]), style: name)),
          SizedBox(width: 80, child: Text(hex(b), style: label)),
          SizedBox(
              width: 150,
              child: NameText('RongYao', paint: NamePaint([a]), style: name)),
          SizedBox(width: 80, child: Text(hex(a), style: label)),
          SizedBox(width: 60, child: ring(b)),
          SizedBox(width: 60, child: ring(aRing)),
        ]),
      );
    }

    return Container(
      color: hollow.background,
      padding: const EdgeInsets.all(HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: HollowTypography.label.copyWith(color: hollow.textPrimary)),
          const SizedBox(height: HollowSpacing.md),
          Row(children: [
            head('', 150),
            head('Picked (swatch)', 110),
            head('Name, before', 230),
            head('Name, after', 230),
            head('Ring, before', 60),
            head('Ring, after', 60),
          ]),
          const SizedBox(height: HollowSpacing.sm),
          row('Editor red', nameColorFromHue(0)),
          row('Editor orange', nameColorFromHue(20)),
          row('Editor amber', nameColorFromHue(40)),
          row('Editor green', nameColorFromHue(150)),
          row('Editor blue', nameColorFromHue(210)),
          row('Editor indigo', nameColorFromHue(250)),
          row('Editor pink', nameColorFromHue(320)),
          row('Reported #C92222', const Color(0xffc92222)), // design-ignore: the reporter's colour
        ],
      ),
    );
  }

  testWidgets('#140 a picked colour, before and after, dark and light',
      (tester) async {
    tester.view.physicalSize = const Size(2200, 2000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Material(
          type: MaterialType.transparency,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            colourSheet(HollowTheme.dark(), 'Dark theme'),
            colourSheet(HollowTheme.light(), 'Light theme'),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await save(tester, 'ui158_140_colours');
  });

  // #140 review: the editor says when the floor moved a pick, and which way.
  testWidgets('#140 the editor and its readability note, dark and light',
      (tester) async {
    tester.view.physicalSize = const Size(2020, 3300);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    const picks = [
      ('Editor red', '1:f42525'),
      ('Reported #C92222', '1:c92222'),
      ('Indigo #4B0082', '1:4b0082'),
      ('Yellow #FFFF00', '1:ffff00'),
      ('Gradient red to indigo', '1:f42525,4b0082'),
    ];
    final containers = <ProviderContainer>[];
    Widget editor(String field, bool dark) {
      final c = ProviderContainer(overrides: hollowTestOverrides());
      containers.add(c);
      c.read(profileDraftProvider.notifier).setNameColor(field);
      final theme = dark ? HollowThemeData.dark() : HollowThemeData.light();
      final hollow = dark ? HollowTheme.dark() : HollowTheme.light();
      return UncontrolledProviderScope(
        container: c,
        child: Theme(
          data: theme,
          child: Container(
            width: 480,
            color: hollow.background,
            padding: const EdgeInsets.all(HollowSpacing.md),
            child: const NameColorEditor(peerId: 'x'),
          ),
        ),
      );
    }

    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Material(
          type: MaterialType.transparency,
          child: Container(
            color: HollowTheme.dark().surface,
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (label, field) in picks) ...[
              Text(label,
                  style: HollowTypography.label
                      .copyWith(color: HollowTheme.dark().textPrimary)),
              Row(mainAxisSize: MainAxisSize.min, children: [
                editor(field, true),
                editor(field, false),
              ]),
            ],
          ]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await save(tester, 'ui158_140_editor_note', ratio: 1.5);
    for (final c in containers) {
      c.dispose();
    }
  });

  // ---------------------------------------------------------------- #158
  testWidgets('#158 the rail at each wheel notch, before and after',
      (tester) async {
    tester.view.physicalSize = const Size(380, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final controller = ItemScrollController();
    final positions = ItemPositionsListener.create();
    final offsets = ScrollOffsetController();
    const count = 28;
    // A voice room's narrow chat: every fourth message is a long paragraph.
    const long = 'the bounce is up, check the low end on the second chorus '
        'because the sub drops out for half a bar right where the snare fill '
        'starts, and the reverb tail on the vocal runs into the next line';
    final hollow = HollowTheme.dark();
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => reversedChatList(
              context: context,
              itemScrollController: controller,
              itemPositionsListener: positions,
              scrollOffsetController: offsets,
              itemCount: count,
              indexByMessageId: {for (var i = 0; i < count; i++) 'm$i': i},
              itemBuilder: (context, rev) {
                final i = count - 1 - rev;
                // Every fourth row stands in for a link card or a sticker.
                return Padding(
                  key: ValueKey('m$i'),
                  padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.lg, vertical: HollowSpacing.xs),
                  child: i % 4 == 0
                      ? Container(
                          height: 300,
                          color: hollow.elevated,
                          padding: const EdgeInsets.all(HollowSpacing.md),
                          child: Text('$i $long',
                              style: HollowTypography.body
                                  .copyWith(color: hollow.textPrimary)),
                        )
                      : Text('$i ok',
                          style: HollowTypography.body
                              .copyWith(color: hollow.textPrimary)),
                );
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final thumbFinder = find.descendant(
      of: find.bySemanticsLabel('Message list scrollbar'),
      matching: find.byType(AnimatedContainer),
    );
    final notches = <(Rect, Rect, Rect)>[]; // track, before thumb, after thumb
    final warm = <Rect>[]; // after, on a second pass up
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    Future<void> wheel(double dy) async {
      await tester.sendEventToBinding(
          mouse.hover(tester.getCenter(find.byType(ScrollablePositionedList))));
      await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
      await tester.pumpAndSettle();
    }
    for (var n = 0; n < 22; n++) {
      final track =
          tester.getRect(find.bySemanticsLabel('Message list scrollbar'));
      final after = tester.getRect(thumbFinder);
      // The 0.14.2 rail: visible share = visible rows / all rows.
      var lo = count, hi = -1;
      for (final p in positions.itemPositions.value) {
        if (p.index < lo) lo = p.index;
        if (p.index > hi) hi = p.index;
      }
      final visible = (hi - lo + 1).clamp(1, count);
      final scrollable = count - visible;
      final offset = scrollable <= 0
          ? 0.0
          : ((count - 1 - hi) / scrollable).clamp(0.0, 1.0);
      final h = (visible / count * track.height).clamp(28.0, track.height);
      final top = track.top + offset * (track.height - h);
      notches.add((
        track,
        Rect.fromLTWH(after.left, top, after.width, h),
        after,
      ));
      await wheel(-90);
    }
    for (var n = 0; n < 30; n++) {
      await wheel(90);
    }
    for (var n = 0; n < 22; n++) {
      warm.add(tester.getRect(thumbFinder));
      await wheel(-90);
    }

    // The sheet: one column per notch, before above after.
    Widget rail(Rect track, Rect thumb, Color ink) => SizedBox(
          width: 14,
          height: track.height,
          child: Stack(children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: hollow.textSecondary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
            Positioned(
              top: thumb.top - track.top,
              height: thumb.height,
              left: 4,
              width: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ]),
        );
    final label = HollowTypography.caption.copyWith(color: hollow.textSecondary);
    tester.view.physicalSize = const Size(900, 2000);
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Material(
          color: hollow.background,
          child: Padding(
            padding: const EdgeInsets.all(HollowSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Chat scrollbar thumb at each mouse-wheel notch up from the '
                    'newest message: 28 rows in a 380 px panel, every fourth a '
                    '300 px card',
                    style: HollowTypography.label
                        .copyWith(color: hollow.textPrimary)),
                const SizedBox(height: HollowSpacing.md),
                Text('Before: sized by the count of visible rows', style: label),
                const SizedBox(height: HollowSpacing.xs),
                Row(children: [
                  for (final (t, b, _) in notches) ...[
                    rail(t, b, hollow.textSecondary),
                    const SizedBox(width: HollowSpacing.sm),
                  ],
                ]),
                const SizedBox(height: HollowSpacing.lg),
                Text('After, first pass: sized from measured row heights '
                    '(unseen rows count as the average)', style: label),
                const SizedBox(height: HollowSpacing.xs),
                Row(children: [
                  for (final (t, _, a) in notches) ...[
                    rail(t, a, hollow.accent),
                    const SizedBox(width: HollowSpacing.sm),
                  ],
                ]),
                const SizedBox(height: HollowSpacing.lg),
                Text('After, second pass: every row measured', style: label),
                const SizedBox(height: HollowSpacing.xs),
                Row(children: [
                  for (var i = 0; i < warm.length; i++) ...[
                    rail(notches[i].$1, warm[i], hollow.accent),
                    const SizedBox(width: HollowSpacing.sm),
                  ],
                ]),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await save(tester, 'ui158_158_rail', ratio: 1.5);
  });

  // ---------------------------------------------------------------- #159
  Future<void> pickerShots(WidgetTester tester,
      {required bool touch, required String prefix}) async {
    debugExpressionPreviewTouch = touch;
    addTearDown(() => debugExpressionPreviewTouch = null);
    final size = touch ? const Size(390, 844) : const Size(760, 560);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final hollow = HollowTheme.dark();
    Widget app() => RepaintBoundary(
          key: shotKey,
          child: ProviderScope(
            overrides: hollowTestOverrides(),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: HollowThemeData.dark(),
              home: Scaffold(
                backgroundColor: hollow.background,
                body: Align(
                  alignment:
                      touch ? Alignment.bottomCenter : Alignment.bottomRight,
                  child: Container(
                    width: touch ? 390 : 360,
                    height: touch ? 560 : 440,
                    margin: touch
                        ? EdgeInsets.zero
                        : const EdgeInsets.all(HollowSpacing.lg),
                    decoration: BoxDecoration(
                      color: hollow.overlay,
                      borderRadius: BorderRadius.circular(
                          touch ? hollow.radiusXl : hollow.radiusLg),
                      border: Border.all(color: hollow.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    // The test has no system emoji font to fall back to.
                    child: DefaultTextStyle.merge(
                      style: const TextStyle(
                          fontFamilyFallback: ['Apple Color Emoji']),
                      child: EmojiPickerBody(serverId: null, onSelect: (_) {}),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final cell = find.bySemanticsLabel('winking face').first;
    await save(tester, '${prefix}_0_picker', ratio: 1.5);
    final g = await tester.startGesture(tester.getCenter(cell),
        kind: touch ? PointerDeviceKind.touch : PointerDeviceKind.mouse);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await save(tester, '${prefix}_1_held', ratio: 1.5);
    await g.up();
    await tester.pumpAndSettle();
    await save(tester, '${prefix}_2_released', ratio: 1.5);
    if (!touch) {
      await tester.tap(cell, buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await save(tester, '${prefix}_3_menu', ratio: 1.5);
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      await save(tester, '${prefix}_4_kept', ratio: 1.5);
      await compose(tester, 'cmp_159_desktop', [
        ('BEFORE: a hold shows nothing, letting go inserts', '${prefix}_0_picker', false),
        ('AFTER: held', '${prefix}_1_held', true),
        ('AFTER: right-click', '${prefix}_3_menu', true),
        ('AFTER: Preview kept', '${prefix}_4_kept', true),
      ]);
    } else {
      await compose(tester, 'cmp_159_phone', [
        ('BEFORE: a hold shows nothing', '${prefix}_0_picker', false),
        ('AFTER: held', '${prefix}_1_held', true),
        ('AFTER: let go, kept', '${prefix}_2_released', true),
      ]);
    }
  }

  testWidgets('#159 desktop: hold, release, right-click Preview',
      (tester) async {
    await pickerShots(tester, touch: false, prefix: 'ui158_159_desktop');
  });

  testWidgets('#159 phone: hold, then the kept preview with its actions',
      (tester) async {
    await pickerShots(tester, touch: true, prefix: 'ui158_159_phone');
  });
}

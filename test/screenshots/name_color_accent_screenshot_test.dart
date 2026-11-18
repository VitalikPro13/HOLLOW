import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/name_text.dart';

/// Screenshot sheet for #140's accent rule: someone else's chosen colour in
/// the accent band turns to the band's edge; only your own name keeps it.
/// "Before" paints the others as they would have been without the turn.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shotKey = Key('screenshot-boundary');
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    final onest = FontLoader('Onest');
    for (final w in [400, 500, 600]) {
      onest.addFont(rootBundle.load('assets/fonts/Onest-$w.ttf'));
    }
    await onest.load();
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

  Widget sheet(HollowTheme hollow, String title) {
    final a = HSLColor.fromColor(hollow.accent).hue;
    final teal = HSLColor.fromAHSL(1, a, 0.7, 0.5).toColor();
    const coral = Color(0xffff6b5e); // design-ignore: fixture pick
    const violet = Color(0xff8a5cff); // design-ignore: fixture pick
    final one = nameColorField([teal]);
    final gradient = nameColorField([coral, teal, violet]);
    final style = HollowTypography.subheading.copyWith(
        fontFamilyFallback: const ['Apple Color Emoji']);

    Widget cell(String name, NamePaint paint) => SizedBox(
          width: 190,
          child: NameText(name, paint: paint, style: style, maxLines: 1),
        );
    Widget row(String what, String name, String field, {bool self = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.md),
          child: Row(children: [
            SizedBox(
              width: 250,
              child: Text(what,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary)),
            ),
            cell(name, namePaintFor(name, hollow, field: field, self: true)),
            cell(name, namePaintFor(name, hollow, field: field, self: self)),
          ]),
        );

    return Container(
      color: hollow.background,
      padding: const EdgeInsets.all(HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: HollowTypography.label.copyWith(color: hollow.textPrimary)),
          const SizedBox(height: HollowSpacing.lg),
          Row(children: [
            const SizedBox(width: 250),
            for (final h in ['Before', 'After'])
              SizedBox(
                width: 190,
                child: Text(h,
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textTertiary)),
              ),
          ]),
          const SizedBox(height: HollowSpacing.sm),
          row('You, teal chosen (your own name)', 'Vitalii', one, self: true),
          row('Someone else, the same teal', 'Bea Lindqvist', one),
          row('Someone else, a gradient with a teal stop', 'Cy Okafor \u{1F30A}',
              gradient),
          Text('The accent: you and the controls',
              style: HollowTypography.bodySmall.copyWith(color: hollow.accentText)),
        ],
      ),
    );
  }

  testWidgets('name colours in the accent band, dark over light',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Builder(builder: (context) {
          return Material(
            type: MaterialType.transparency,
            child: Column(children: [
              sheet(HollowTheme.dark(), 'Dark theme, default teal accent'),
              sheet(HollowTheme.light(), 'Light theme, default teal accent'),
            ]),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(shotKey));
    final image = await tester.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 2.0);
      return img.toByteData(format: ui.ImageByteFormat.png);
    });
    Directory(outDir).createSync(recursive: true);
    File('$outDir${Platform.pathSeparator}name_color_accent.png')
        .writeAsBytesSync(image!.buffer.asUint8List());
  });
}

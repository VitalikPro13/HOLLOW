import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';

import '../helpers/test_app.dart';

/// Screenshot harness for the typing label on the seam between the message
/// list and the composer: a driven app can not hold a peer's typing notice
/// still long enough to shoot it, so the placement is judged here, in both
/// themes, against the real composer row.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shotKey = Key('screenshot-boundary');
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    final fontData = await rootBundle
        .load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(fontData)))
        .load();
    try {
      final segoe = File(r'C:\Windows\Fonts\segoeui.ttf');
      if (segoe.existsSync()) {
        final bytes = segoe.readAsBytesSync();
        for (final family in ['FlutterTest', 'Ahem', 'Roboto']) {
          await (FontLoader(family)
                ..addFont(Future.value(ByteData.view(bytes.buffer))))
              .load();
        }
      }
    } catch (_) {/* falls back to block glyphs */}
  });

  Future<void> shoot(WidgetTester tester,
      {required ThemeData theme, required String name}) async {
    tester.view.physicalSize = const Size(720, 220);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = EmoteComposerController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: Builder(builder: (context) {
            final hollow = HollowTheme.of(context);
            return Scaffold(
              backgroundColor: hollow.background,
              body: Column(children: [
                const Expanded(
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(64, 0, 16, 16),
                      child: Text('perfect, around for a call later?'),
                    ),
                  ),
                ),
                TypingIndicatorHost(
                  names: const ['probe-b'],
                  child: chatInputBarShell(
                    hollow,
                    flushTop: false,
                    child: ChatComposerRow(
                      controller: controller,
                      focusNode: focus,
                      hintText: 'Message probe-b',
                      onChanged: (_) {},
                      onKey: (_) => KeyEventResult.ignored,
                      layerLink: LayerLink(),
                      onExpressions: (_) {},
                      onSend: () {},
                      autofocus: false,
                    ),
                  ),
                ),
              ]),
            );
          }),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 400));

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      try {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data == null) return;
        final file = File('$outDir${Platform.pathSeparator}$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data.buffer.asUint8List());
      } catch (_) {}
    });
    expect(find.text('probe-b is typing'), findsOneWidget);
    // Unmount so the typing dots release the shared ticker.
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('typing label, dark', (tester) async {
    await shoot(tester, theme: HollowThemeData.dark(), name: 'typing_label_dark');
  });

  testWidgets('typing label, light', (tester) async {
    await shoot(tester,
        theme: HollowThemeData.light(), name: 'typing_label_light');
  });
}

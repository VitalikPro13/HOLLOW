import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';

/// Screenshot harness for the three shapes a chat row's separator can take
/// (issue #54): a plain day rule, the unread line on its own, and the two
/// MERGED into one rule.
///
/// It exists because the merged case is the one nobody can produce on demand:
/// it needs the first unread message to also be the first message of a new
/// day, which is the most ordinary way to meet this line in real use and the
/// hardest to stage in a driven app, where every message lands today. The
/// widget tests assert the STRUCTURE; this is how the balance of the rule, the
/// day label and the badge gets judged by eye, in both themes.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
/// Writing is best-effort — an unwritable dir never fails the suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shotKey = Key('screenshot-boundary');
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    try {
      final segoe = File(r'C:\Windows\Fonts\segoeui.ttf');
      if (segoe.existsSync()) {
        final bytes = segoe.readAsBytesSync();
        for (final family in ['FlutterTest', 'Ahem', 'Roboto']) {
          final l = FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer)));
          await l.load();
        }
      }
    } catch (_) {/* falls back to block glyphs */}
  });

  Widget row(String text, {required bool date, required bool unread}) =>
      dateSeparatedChatRow(
        rowKey: text,
        timestamp: DateTime(2026, 1, 5, 12),
        prevTimestamp: date ? DateTime(2026, 1, 4, 12) : DateTime(2026, 1, 5, 11),
        showHeader: false,
        railGutter: true,
        unreadDivider: unread,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(52, 2, 12, 2),
          child: Text(text),
        ),
      );

  Future<void> shoot(WidgetTester tester,
      {required ThemeData theme, required String name}) async {
    tester.view.physicalSize = const Size(900, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Scaffold(
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row('a message before the day turns',
                      date: false, unread: false),
                  row('a new day, nothing unread', date: true, unread: false),
                  row('more of the same day', date: false, unread: false),
                  row('the first message you have not read',
                      date: false, unread: true),
                  row('and the one after it', date: false, unread: false),
                  row('unread AND a new day: one rule, not two',
                      date: true, unread: true),
                  row('the last row', date: false, unread: false),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

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
        debugPrint('[screenshot] wrote ${file.path}');
      } catch (e) {
        debugPrint('[screenshot] skipped: $e');
      }
    });
  }

  testWidgets('chat separators — dark', (tester) async {
    await shoot(tester, theme: HollowThemeData.dark(), name: 'chat_separators_dark');
    // The merged rule is the regression that matters: two full-width rules
    // 30px apart is the double-rule problem this fixed.
    expect(find.byType(DateSeparator), findsNWidgets(1));
    expect(find.byType(UnreadDivider), findsNWidgets(2));
  });

  testWidgets('chat separators — light', (tester) async {
    await shoot(tester,
        theme: HollowThemeData.light(), name: 'chat_separators_light');
    // The badge and the day label both have to survive the light palette —
    // raw error red fails as small text there, which is why the label runs
    // through Contrast.ensureContrast.
    expect(find.text('New'), findsNWidgets(2));
  });
}

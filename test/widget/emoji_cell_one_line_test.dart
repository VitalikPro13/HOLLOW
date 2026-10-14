import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';

/// Issue #104 follow-up: Windows 10's Segoe UI Emoji draws a combined emoji
/// newer than it ("face exhaling") as its pieces. The test font does the same,
/// so a cell must keep the pieces on one line inside itself instead of
/// wrapping and stretching its row of the grid.
void main() {
  testWidgets('a combined emoji drawn as pieces stays on one line in its cell',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showEmojiPicker(
                  context: context,
                  anchorPosition: const Offset(400, 500),
                  onSelect: (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'exhaling');
    await tester.pumpAndSettle();

    final glyph = find.text('😮‍💨');
    expect(glyph, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(glyph);
    final oneLine = TextPainter(
      text: paragraph.text,
      textScaler: paragraph.textScaler,
      textDirection: TextDirection.ltr,
    )..layout();
    expect(paragraph.size.height, closeTo(oneLine.height, 0.5),
        reason: 'the pieces wrapped onto a second line');
    oneLine.dispose();

    final cell = find
        .ancestor(of: glyph, matching: find.bySemanticsLabel('face exhaling'))
        .first;
    final cellRect = tester.getRect(cell);
    final glyphRect = tester.getRect(glyph);
    expect(cellRect.contains(glyphRect.topLeft) &&
        cellRect.contains(glyphRect.bottomRight - const Offset(0.5, 0.5)),
        isTrue,
        reason: 'the glyph spills out of its cell');
    expect(tester.takeException(), isNull);
  });
}

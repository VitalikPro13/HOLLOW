import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/message_row.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';

import '../helpers/test_app.dart';

/// Issue #108: a grouped row's hover time sits in the 36 px avatar column, and
/// at a larger text scale "14:05" wrapped to "14:0" over "5". The time stays on
/// one line inside its column at every scale, shrinking rather than wrapping.
class _Display extends MessageDisplayNotifier {
  final MessageDisplay value;
  _Display(this.value);
  @override
  MessageDisplay build() => value;
}

Widget _row({
  required double textScale,
  required bool showHeader,
  MessageDisplay display = MessageDisplay.cozy,
}) =>
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        messageDisplayProvider.overrideWith(() => _Display(display)),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(800, 600),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: HoverScope(
              hovered: ValueNotifier(true),
              child: MessageRow(
                messageId: 'm1',
                senderId: 'peer-b',
                isMe: false,
                text: 'grouped line',
                timestamp: DateTime(2026, 10, 14, 14, 5),
                editedAt: null,
                replyToMid: null,
                reactions: const {},
                fileAttachment: null,
                linkPreview: null,
                showHeader: showHeader,
              ),
            ),
          ),
        ),
      ),
    );

/// The time's laid-out size against one unconstrained line of the same text:
/// the same height means it did not wrap, the same width that no digit was
/// cut off at the column's edge.
void _expectOneLine(WidgetTester tester, Finder time) {
  final paragraph = tester.renderObject<RenderParagraph>(time);
  final painter = TextPainter(
    text: paragraph.text,
    textScaler: paragraph.textScaler,
    textDirection: TextDirection.ltr,
  )..layout();
  expect(paragraph.size.height, closeTo(painter.height, 0.5),
      reason: 'the time wrapped onto a second line');
  expect(paragraph.size.width, greaterThanOrEqualTo(painter.width - 0.5),
      reason: 'the time was clipped instead of shrunk');
  painter.dispose();
}

/// The real faces, so widths match the app rather than the square test font.
Future<void> _loadFonts() async {
  for (final (family, files) in const [
    ('GeistMono', ['GeistMono-400.ttf', 'GeistMono-500.ttf']),
    ('Onest', ['Onest-400.ttf', 'Onest-500.ttf', 'Onest-600.ttf']),
  ]) {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await loader.load();
  }
}

void main() {
  setUpAll(_loadFonts);

  for (final scale in const [1.0, 1.25, 1.5, 2.0]) {
    testWidgets('hover time stays on one line in the avatar column at ${scale}x',
        (tester) async {
      await tester.pumpWidget(_row(textScale: scale, showHeader: false));
      await tester.pump();
      final time = find.text('14:05');
      expect(time, findsOneWidget);
      _expectOneLine(tester, time);

      final rowLeft = tester.getTopLeft(find.byType(MessageRow)).dx +
          MessageRow.horizontalInset;
      final rect = tester.getRect(time);
      expect(rect.left, greaterThanOrEqualTo(rowLeft - 0.5),
          reason: 'the time spills left of its column');
      expect(rect.right, lessThanOrEqualTo(rowLeft + kMessageAvatarSize + 0.5),
          reason: 'the time spills into the message text');
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact time stays on one line at ${scale}x', (tester) async {
      await tester.pumpWidget(_row(
          textScale: scale,
          showHeader: false,
          display: MessageDisplay.compact));
      await tester.pump();
      final time = find.text('14:05');
      expect(time, findsOneWidget);
      _expectOneLine(tester, time);
      // Never under the sender's name that follows the column.
      final name = tester.getRect(find.byType(RichText).at(1));
      expect(tester.getRect(time).right, lessThanOrEqualTo(name.left));
      // Every compact row shows its time, so the column grows with the text
      // instead of shrinking it.
      expect(tester.getRect(time).width,
          closeTo(tester.renderObject<RenderParagraph>(time).size.width, 0.5),
          reason: 'the compact time was shrunk');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a longer time (12-hour form) still fits the compact column',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MessageTimeLabel('12:45 PM', width: 40),
          ),
        ),
      ),
    ));
    final time = find.text('12:45 PM');
    _expectOneLine(tester, time);
    expect(tester.getRect(time).width, lessThanOrEqualTo(40.5));
    expect(tester.takeException(), isNull);
  });
}

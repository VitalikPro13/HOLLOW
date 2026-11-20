/// A name leading a sentence ("Ada is typing"): the names shorten first, the
/// line never spills past its row, and a screen reader hears one sentence.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/components/name_text.dart';

const _red = Color(0xffff0000); // design-ignore: test fixture colour
const _style = TextStyle(fontSize: 12); // design-ignore: test glyph size

Widget _row(double width, Widget line) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(width: width, child: Row(children: [Flexible(child: line)])),
      ),
    );

void main() {
  for (final width in [240.0, 120.0, 60.0, 24.0]) {
    testWidgets('a name line never spills past a ${width.round()} px row',
        (tester) async {
      await tester.pumpWidget(_row(
          width,
          NameLine(
            name: 'Ada Lovelace',
            paint: const NamePaint([_red]),
            rest: ' is sharing their screen',
            style: _style,
          )));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(_row(
          width,
          NameLine.several(
            names: [
              ('Ada Lovelace', const NamePaint([_red])),
              ('Bo', const NamePaint([_red])),
              ('Charlotte', const NamePaint([_red])),
            ],
            joins: const [', ', ', and '],
            rest: ' are typing',
            style: _style,
          )));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the name gives way before the rest of the sentence',
      (tester) async {
    await tester.pumpWidget(_row(
        300,
        NameLine(
          name: 'Ada Augusta Lovelace of Ockham',
          paint: const NamePaint([_red]),
          rest: ' is typing',
          style: _style,
        )));
    final name = tester.renderObject<RenderParagraph>(
        find.text('Ada Augusta Lovelace of Ockham'));
    final rest = tester.renderObject<RenderParagraph>(find.text(' is typing'));
    expect(name.didExceedMaxLines, isTrue, reason: 'the name is shortened');
    expect(rest.didExceedMaxLines, isFalse, reason: 'the rest shows whole');
  });

  testWidgets('a screen reader hears one sentence', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_row(
        120,
        NameLine.several(
          names: [
            ('Ada Lovelace', const NamePaint([_red])),
            ('Bo', const NamePaint([_red])),
          ],
          joins: const [' and '],
          rest: ' are typing',
          style: _style,
        )));
    expect(find.bySemanticsLabel('Ada Lovelace and Bo are typing'),
        findsOneWidget);
    expect(find.bySemanticsLabel('Ada Lovelace'), findsNothing);
    handle.dispose();
  });

  testWidgets('the typing line draws each name in its colour',
      (tester) async {
    const blue = Color(0xff3366ff); // design-ignore: test fixture colour
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: TypingIndicatorBar(
            names: const ['Ada', 'Bo'],
            paints: [const NamePaint([_red]), const NamePaint([blue])],
          ),
        ),
      ),
    ));
    expect(tester.widget<Text>(find.text('Ada')).style?.color, _red);
    expect(tester.widget<Text>(find.text('Bo')).style?.color, blue);
    expect(find.text(' are typing'), findsOneWidget);
  });
}

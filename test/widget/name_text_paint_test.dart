/// #149: a gradient name must draw its whole gradient wherever it sits.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/ui/components/name_text.dart';

const _red = Color(0xffff0000); // design-ignore: test fixture colour
const _blue = Color(0xff0000ff); // design-ignore: test fixture colour

/// Mean red and blue over the left and right fifths of the name's own box,
/// or of [rect] inside it.
Future<(double, double, double, double)> _ends(
    WidgetTester tester, GlobalKey boundary,
    {String text = 'MMMMMMMM', Rect? rect}) async {
  final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final name = rect ?? tester.getRect(find.text(text));
  final origin = tester.getTopLeft(find.byKey(boundary));
  final image = await tester.runAsync(() => ro.toImage());
  final data = await tester
      .runAsync(() => image!.toByteData(format: ui.ImageByteFormat.rawRgba));
  final w = image!.width;
  (double, double) mean(double from, double to) {
    var r = 0.0, b = 0.0, n = 0;
    for (var y = name.top; y < name.bottom; y++) {
      for (var x = from; x < to; x++) {
        final px = ((y - origin.dy).round() * w + (x - origin.dx).round()) * 4;
        final a = data!.getUint8(px + 3);
        if (a < 200) continue;
        final rr = data.getUint8(px), bb = data.getUint8(px + 2);
        if (rr + bb < 120) continue; // background
        r += rr;
        b += bb;
        n++;
      }
    }
    return n == 0 ? (0, 0) : (r / n, b / n);
  }

  final fifth = name.width / 5;
  final (lr, lb) = mean(name.left, name.left + fifth);
  final (rr, rb) = mean(name.right - fifth, name.right);
  return (lr, lb, rr, rb);
}

void main() {
  final paint = NamePaint(const [_red, _blue]);

  Future<void> check(WidgetTester tester, String label,
      Widget Function(Widget name) wrap) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: boundary,
        child: ColoredBox(
          color: const Color(0xff000000), // design-ignore: test backdrop
          child: wrap(Align(alignment: Alignment.topLeft, widthFactor: 1, heightFactor: 1, child: NameText('MMMMMMMM',
              paint: paint,
              maxLines: 1,
              style: const TextStyle(fontSize: 40)))), // design-ignore: test glyph size
        ),
      ),
    ));
    await tester.pump();
    final (lr, lb, rr, rb) = await _ends(tester, boundary);
    expect(lr, greaterThan(lb), reason: '$label: the left end is red');
    expect(rb, greaterThan(rr), reason: '$label: the right end is blue');
  }

  testWidgets('a gradient name draws both ends, plain', (tester) async {
    await check(tester, 'plain', (n) => Padding(
        padding: const EdgeInsets.only(left: 300, top: 400), child: n)); // design-ignore: test offset
  });

  testWidgets('a gradient name draws both ends in a selectable list row',
      (tester) async {
    await check(
        tester,
        'list',
        (n) => ListView(children: [
              const SizedBox(height: 400), // design-ignore: test offset
              SelectionArea(
                child: Row(children: [
                  const SizedBox(width: 300), // design-ignore: test offset
                  Flexible(child: n),
                ]),
              ),
            ]));
  });

  testWidgets('a gradient name draws both ends under a composited layer',
      (tester) async {
    await check(
        tester,
        'opacity',
        (n) => Padding(
              padding: const EdgeInsets.only(left: 300, top: 400), // design-ignore: test offset
              child: AnimatedOpacity(
                  opacity: 0.99,
                  duration: Duration.zero,
                  child: RepaintBoundary(child: n)),
            ));
  });

  Future<void> pumpName(WidgetTester tester, GlobalKey boundary, String text,
      {required double width, int? maxLines, TextOverflow? overflow}) async {
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: boundary,
        child: ColoredBox(
          color: const Color(0xff000000), // design-ignore: test backdrop
          child: Padding(
            padding: const EdgeInsets.only(left: 40, top: 200), // design-ignore: test offset
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: NameText(text,
                    paint: paint,
                    maxLines: maxLines,
                    overflow: overflow,
                    style: const TextStyle(fontSize: 40)), // design-ignore: test glyph size
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('an ellipsized name ends on its last stop', (tester) async {
    final boundary = GlobalKey();
    const long = 'MMMMMMMMMMMMMMMM';
    await pumpName(tester, boundary, long,
        width: 300, maxLines: 1, overflow: TextOverflow.ellipsis); // design-ignore: test width
    final (lr, lb, rr, rb) = await _ends(tester, boundary, text: long);
    expect(lr, greaterThan(lb), reason: 'the left end is red');
    expect(rb, greaterThan(rr),
        reason: 'the shown end is blue, not the middle of the unbroken name');
  });

  testWidgets('every line of a wrapped name spans the gradient',
      (tester) async {
    final boundary = GlobalKey();
    const two = 'MMMM MMMM';
    await pumpName(tester, boundary, two, width: 170); // design-ignore: test width
    final box = tester.getRect(find.text(two));
    expect(box.height, greaterThan(60), reason: 'it wraps to two lines');
    for (final (label, line) in [
      ('first', Rect.fromLTRB(box.left, box.top, box.left + 160, box.top + 40)),
      ('second',
          Rect.fromLTRB(box.left, box.top + 40, box.left + 160, box.top + 80)),
    ]) {
      final (lr, lb, rr, rb) = await _ends(tester, boundary, rect: line);
      expect(lr, greaterThan(lb), reason: '$label line starts red');
      expect(rb, greaterThan(rr), reason: '$label line ends blue');
    }
  });

  // A rebuild hands the paragraph the widget's fresh foreground; the gradient
  // has to go back on over the same render object.
  for (final tight in [false, true]) {
  testWidgets('a rebuilt name keeps its gradient${tight ? ' in a fixed box' : ''}',
      (tester) async {
    final boundary = GlobalKey();
    final tick = ValueNotifier(0);
    addTearDown(tick.dispose);
    await tester.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: boundary,
        child: ColoredBox(
          color: const Color(0xff000000), // design-ignore: test backdrop
          child: Padding(
            padding: const EdgeInsets.only(left: 300, top: 400), // design-ignore: test offset
            child: Align(
              alignment: Alignment.topLeft,
              child: ValueListenableBuilder<int>(
                valueListenable: tick,
                builder: (_, _, _) {
                  final name = NameText('MMMMMMMM',
                      paint: paint,
                      maxLines: 1,
                      style: const TextStyle(fontSize: 40)); // design-ignore: test glyph size
                  // A fixed box makes the paragraph its own relayout boundary.
                  return tight
                      ? SizedBox(width: 320, height: 40, child: name) // design-ignore: test size
                      : name;
                },
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    final before = tester.renderObject(find.text('MMMMMMMM'));
    tick.value++;
    await tester.pump();
    expect(tester.renderObject(find.text('MMMMMMMM')), same(before));
    final (lr, lb, rr, rb) = await _ends(tester, boundary);
    expect(lr, greaterThan(lb), reason: 'the left end is red');
    expect(rb, greaterThan(rr), reason: 'the right end is blue');
  });
  }
}

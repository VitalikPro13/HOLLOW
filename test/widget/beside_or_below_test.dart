/// BesideOrBelow: the trail sits beside the lead only when it leaves the lead
/// its natural width or two fifths of the row; otherwise it goes under.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/components/beside_or_below.dart';

const _trail = Key('trail');
const _lead = Key('lead');

Future<void> _pump(WidgetTester tester, String lead, double trailWidth,
        {double leadShare = BesideOrBelow.defaultLeadShare}) =>
    tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          child: BesideOrBelow(
            leadShare: leadShare,
            lead: Text(lead, key: _lead, style: const TextStyle(fontSize: 10)),
            trail: SizedBox(key: _trail, width: trailWidth, height: 20),
          ),
        ),
      ),
    ));

bool _below(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_trail)).dy >=
    tester.getBottomLeft(find.byKey(_lead)).dy;

void main() {
  testWidgets('a short lead keeps a wide trail beside it', (tester) async {
    await _pump(tester, 'Hi', 300);
    expect(_below(tester), isFalse);
    expect(tester.getTopRight(find.byKey(_trail)).dx, 400);
  });

  testWidgets('a long lead is never squeezed under two fifths of the row',
      (tester) async {
    // 300 + 16 leaves 84 px, more than any one word but under 160.
    await _pump(tester, List.filled(30, 'aaa').join(' '), 300);
    expect(_below(tester), isTrue);
    expect(tester.getTopLeft(find.byKey(_trail)).dx, 0);
  });

  testWidgets('a larger lead share sends the trail below sooner',
      (tester) async {
    // 140 + 16 leaves 244 px: over two fifths (160), under three fifths (240
    // is the share, so 244 still fits) and under 0.65 (260).
    final lead = List.filled(30, 'aaa').join(' ');
    await _pump(tester, lead, 140);
    expect(_below(tester), isFalse);
    await _pump(tester, lead, 140, leadShare: 0.65);
    expect(_below(tester), isTrue);
  });

  testWidgets('a long lead with a small trail stays beside', (tester) async {
    await _pump(tester, List.filled(30, 'aaa').join(' '), 100);
    expect(_below(tester), isFalse);
  });
}

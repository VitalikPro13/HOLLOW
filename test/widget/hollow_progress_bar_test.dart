import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_progress_bar.dart';

Future<HollowTheme> _pump(WidgetTester tester, Widget bar) async {
  late HollowTheme hollow;
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(
      body: Builder(builder: (context) {
        hollow = HollowTheme.of(context);
        return Center(child: SizedBox(width: 200, child: bar));
      }),
    ),
  ));
  return hollow;
}

Size _fillSize(WidgetTester tester) => tester.getSize(find.descendant(
      of: find.byType(FractionallySizedBox),
      matching: find.byType(DecoratedBox),
    ));

void main() {
  testWidgets('is 4 px tall and fills by value', (tester) async {
    await _pump(tester, const HollowProgressBar(value: 0.25));
    expect(tester.getSize(find.byType(HollowProgressBar)).height,
        HollowProgressBar.height);
    expect(_fillSize(tester).width, 50);
  });

  testWidgets('clamps out-of-range and NaN values', (tester) async {
    await _pump(tester, const HollowProgressBar(value: 3));
    expect(_fillSize(tester).width, 200);
    await _pump(tester, const HollowProgressBar(value: double.nan));
    expect(_fillSize(tester).width, 0);
  });

  testWidgets('fills in the accent unless a tone is given', (tester) async {
    final hollow = await _pump(tester, const HollowProgressBar(value: 0.5));
    Color fill() => ((tester.widget<DecoratedBox>(find.descendant(
          of: find.byType(FractionallySizedBox),
          matching: find.byType(DecoratedBox),
        ))).decoration as BoxDecoration).color!;
    expect(fill(), hollow.accent);
    await _pump(tester, HollowProgressBar(value: 0.5, color: hollow.success));
    expect(fill(), hollow.success);
  });
}

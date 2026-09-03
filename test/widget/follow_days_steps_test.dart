import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/follow_days_steps.dart';

/// The Twitch join gate can only ask for one of the follow-age steps the shop
/// signs, so the server setting offers exactly those steps and nothing else.
/// A legacy value between two steps shows the step the gate really enforces.
Future<void> _pump(
  WidgetTester tester,
  int value,
  ValueChanged<int> onChanged,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: FollowDaysSteps(value: value, onChanged: onChanged),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('the steps are the ten the shop signs, in order', () {
    expect(kFollowDaySteps, [0, 1, 3, 7, 14, 30, 60, 90, 180, 365]);
  });

  test('a value between two steps enforces the next step up', () {
    expect(effectiveFollowStep(0), 0);
    expect(effectiveFollowStep(7), 7);
    expect(effectiveFollowStep(10), 14);
    expect(effectiveFollowStep(366), 365);
  });

  testWidgets('every step is a chip and tapping one reports it',
      (tester) async {
    int? picked;
    await _pump(tester, 0, (v) => picked = v);
    for (final step in kFollowDaySteps.skip(1)) {
      expect(find.text('$step'), findsOneWidget);
    }
    expect(find.text('any'), findsOneWidget);
    await tester.tap(find.text('30'));
    await tester.pump();
    expect(picked, 30);
  });

  testWidgets('a legacy value shows the step it is enforced as',
      (tester) async {
    await _pump(tester, 10, (_) {});
    final chip = tester.widget<Text>(find.text('14'));
    final other = tester.widget<Text>(find.text('7'));
    expect(chip.style?.color, isNot(equals(other.style?.color)));
  });
}

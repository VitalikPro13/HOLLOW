// Issue #37: the voice-channel participant row's speaking cue is an outline
// around the avatar. It replaced a SpeakingBorder, which pads its child
// outward — in a dense sidebar row that showed up as a fat avatar sitting a
// visible gap inside its own ring, and every row's geometry changed.
//
// These pin the two properties that fix demanded: the cue costs NOTHING in
// layout, and it hugs the avatar instead of standing off it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/speaking_border.dart';

const _avatar = 18.0;
const _border = 2.0;

Widget _host({required bool speaking}) => MaterialApp(
      theme: ThemeData(extensions: [HollowTheme.dark()]),
      home: Scaffold(
        body: Center(
          child: SpeakingAvatarOutline(
            isSpeaking: speaking,
            size: _avatar,
            radius: 8,
            borderWidth: _border,
            child: const SizedBox(
              key: ValueKey('avatar'),
              width: _avatar,
              height: _avatar,
              child: ColoredBox(color: Color(0xFF00FF00)),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the outline takes no layout space in either state',
      (tester) async {
    await tester.pumpWidget(_host(speaking: false));
    await tester.pumpAndSettle();
    final silent = tester.getSize(find.byType(SpeakingAvatarOutline));

    await tester.pumpWidget(_host(speaking: true));
    await tester.pumpAndSettle();
    final talking = tester.getSize(find.byType(SpeakingAvatarOutline));

    expect(silent, const Size(_avatar, _avatar),
        reason: 'the cue must not widen the row');
    expect(talking, silent,
        reason: 'the row must not shift when someone starts talking');
  });

  testWidgets('the outline hugs the avatar edge with no gap', (tester) async {
    await tester.pumpWidget(_host(speaking: true));
    await tester.pumpAndSettle();

    final avatar = tester.getRect(find.byKey(const ValueKey('avatar')));
    final ring = tester.getRect(find.descendant(
      of: find.byType(SpeakingAvatarOutline),
      matching: find.byType(DecoratedBox),
    ));

    // The ring's box is inset negatively by exactly one border width, so its
    // INNER edge lands on the avatar's edge: outside the art, no gap.
    expect(ring.left, moreOrLessEquals(avatar.left - _border, epsilon: 0.01));
    expect(ring.top, moreOrLessEquals(avatar.top - _border, epsilon: 0.01));
    expect(ring.right, moreOrLessEquals(avatar.right + _border, epsilon: 0.01));
    expect(
        ring.bottom, moreOrLessEquals(avatar.bottom + _border, epsilon: 0.01));
  });
}

// Motion (design language 3.8): a menu grows around the click point, never a
// corner of the screen; a big panel rises 8 px without scaling; the typing
// label floats on the composer's edge without moving anything.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/popup_animator.dart';

import '../helpers/test_app.dart';

Widget _app(Widget child) => ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('a menu opened far from the origin stays at its click point',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late BuildContext ctx;
    await tester.pumpWidget(_app(Builder(builder: (c) {
      ctx = c;
      return const SizedBox.expand();
    })));

    const anchor = Offset(900, 300);
    showHollowMenu(
      context: ctx,
      anchor: anchor,
      builder: (_, _) => [HollowMenuItem(label: 'Copy', onTap: () {})],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final early = tester.getTopLeft(find.text('Copy'));
    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(find.text('Copy'));

    // Scaled around the anchor, every point starts nearer the anchor than it
    // ends; scaled around the screen's corner, it would start farther away.
    final ratio = (early - anchor).distance / (settled - anchor).distance;
    expect(ratio, lessThan(1));
    expect(ratio, greaterThanOrEqualTo(HollowMotion.popoverScale - 0.001));
  });

  testWidgets('a rising panel keeps its size and travels 8 px at most',
      (tester) async {
    await tester.pumpWidget(_app(const Center(
      child: PopupAnimator(
        rise: true,
        alignment: Alignment.bottomRight,
        child: SizedBox(key: Key('panel'), width: 360, height: 440),
      ),
    )));
    await tester.pump(const Duration(milliseconds: 20));
    final early = tester.getRect(find.byKey(const Key('panel')));
    await tester.pumpAndSettle();
    final settled = tester.getRect(find.byKey(const Key('panel')));

    expect(early.width, moreOrLessEquals(settled.width),
        reason: 'a big panel never scales');
    expect(early.height, moreOrLessEquals(settled.height));
    expect(early.top - settled.top, greaterThan(0),
        reason: 'a panel above its button starts lower');
    expect(early.top - settled.top, lessThanOrEqualTo(HollowMotion.rise));
    expect(early.left, moreOrLessEquals(settled.left));
  });

  testWidgets('someone typing moves neither the list nor the composer',
      (tester) async {
    Future<(Rect, Rect)> layoutWith(List<String> names) async {
      await tester.pumpWidget(_app(Column(children: [
        const Expanded(child: SizedBox.expand(key: Key('list'))),
        TypingIndicatorHost(
          names: names,
          child: const SizedBox(key: Key('composer'), height: 56),
        ),
      ])));
      await tester.pumpAndSettle();
      return (
        tester.getRect(find.byKey(const Key('list'))),
        tester.getRect(find.byKey(const Key('composer'))),
      );
    }

    final idle = await layoutWith(const []);
    expect(find.byType(TypingIndicatorBar), findsNothing,
        reason: 'nothing shows while nobody types');
    final typing = await layoutWith(const ['probe-b']);
    expect(find.text('probe-b is typing'), findsOneWidget);
    expect(typing, idle);

    // The label sits on the seam, mostly over the list's bottom padding.
    final label = tester.getRect(find.byType(TypingIndicatorBar));
    expect(label.top, lessThan(typing.$2.top));
    expect(label.bottom, greaterThan(typing.$2.top));
    expect(label.bottom - typing.$2.top, lessThanOrEqualTo(HollowSpacing.sm));
  });
}

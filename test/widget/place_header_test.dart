import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/place_header.dart';

Future<void> _pump(WidgetTester tester, PlaceHeader header) async {
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 700, child: header),
      ),
    ),
  ));
}

void main() {
  testWidgets('actions sit on the trailing edge, whatever the title',
      (tester) async {
    await _pump(
      tester,
      const PlaceHeader(
        title: 'Share',
        tabs: [SizedBox(width: 80, height: 28)],
        actions: [SizedBox(key: Key('action'), width: 100, height: 32)],
      ),
    );
    expect(tester.getTopRight(find.byKey(const Key('action'))).dx,
        700 - HollowSpacing.lg);
  });

  testWidgets('keeps one height with or without actions', (tester) async {
    await _pump(tester, const PlaceHeader(title: 'Archive'));
    final bare = tester.getSize(find.byType(PlaceHeader)).height;
    await _pump(
      tester,
      const PlaceHeader(
        title: 'Archive',
        actions: [SizedBox(width: 120, height: 32)],
      ),
    );
    expect(tester.getSize(find.byType(PlaceHeader)).height, bare);
    expect(bare, kPlaceHeaderHeight);
  });

  testWidgets('a long title ellipsizes instead of pushing the actions',
      (tester) async {
    await _pump(
      tester,
      PlaceHeader(
        title: 'A meeting with a very long name ' * 8,
        actions: const [SizedBox(key: Key('end'), width: 120, height: 32)],
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getTopRight(find.byKey(const Key('end'))).dx,
        700 - HollowSpacing.lg);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/support_glyph.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _peer = 'peer_support_chip_0001';

SupportCredInfo _mark(String item, String title) => SupportCredInfo(
      cred: SupportCred(item: item, parts: const {}, badge: true),
      artist: 'VitalikPro13',
      title: title,
    );

Future<void> _pump(WidgetTester tester, List<SupportCredInfo> marks,
        {bool touch = false}) =>
    tester.pumpWidget(ProviderScope(
      overrides: [
        supportMarkInfosProvider(_peer).overrideWith((_) => marks),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(child: SupportMarksChip(peerId: _peer, touch: touch)),
        ),
      ),
    ));

void main() {
  testWidgets('one mark is the icon alone, its piece in the tooltip',
      (tester) async {
    await _pump(tester, [_mark('a' * 64, 'Headphones')]);
    expect(find.textContaining('Supported'), findsNothing);
    expect(find.text('×1'), findsNothing);
    final tooltip = tester.widget<HollowTooltip>(find.byType(HollowTooltip));
    expect(tooltip.message, contains('VitalikPro13: Headphones'));
  });

  testWidgets('several marks add only a count', (tester) async {
    await _pump(tester, [
      _mark('a' * 64, 'Headphones'),
      _mark('b' * 64, 'Listening'),
    ]);
    expect(find.text('×2'), findsOneWidget);
    expect(find.textContaining('Supported'), findsNothing);
  });

  // A phone has no hover, so the tooltip never showed and a tap did nothing.
  testWidgets('on a phone a tap opens the pieces in a sheet', (tester) async {
    await _pump(
        tester,
        [
          _mark('a' * 64, 'Headphones'),
          _mark('b' * 64, 'Listening'),
        ],
        touch: true);
    await tester.tap(find.bySemanticsLabel('Supports artists, 2 pieces'));
    await tester.pumpAndSettle();
    expect(find.text('Supports independent artists'), findsOneWidget);
    expect(find.text('Headphones'), findsOneWidget);
    expect(find.text('Listening'), findsOneWidget);
    expect(find.text('by VitalikPro13'), findsNWidgets(2));
  });

  // It sits beside the Twitch chip on the profile and read a size smaller.
  testWidgets('the mark stands as tall as a chip beside it', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        supportMarkInfosProvider(_peer)
            .overrideWith((_) => [_mark('a' * 64, 'Headphones')]),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SupportMarksChip(peerId: _peer),
                HollowChip(label: 'anonlisten', onTap: () {}),
              ],
            ),
          ),
        ),
      ),
    ));
    expect(
      tester.getSize(find.byType(SupportMarksChip)).height,
      tester.getSize(find.byType(HollowChip)).height,
    );
  });

  // The profile corner on a phone is a fingertip high; a target padded a fixed
  // amount above the mark squeezed the mark back below the chip.
  testWidgets('on a phone the mark stays as tall as the chip in the corner',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        supportMarkInfosProvider(_peer)
            .overrideWith((_) => [_mark('a' * 64, 'Headphones')]),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const SupportMarksChip(peerId: _peer, touch: true),
                  HollowChip(label: 'anonlisten', onTap: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    final mark = find
        .ancestor(
            of: find.byIcon(LucideIcons.sparkles),
            matching: find.byType(Container))
        .first;
    expect(tester.getSize(mark).height,
        tester.getSize(find.byType(HollowChip)).height);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone-sized mark is a fingertip-sized target', (tester) async {
    await _pump(tester, [_mark('a' * 64, 'Headphones')], touch: true);
    final size = tester.getSize(find.bySemanticsLabel('Supports an artist'));
    expect(size.height, greaterThanOrEqualTo(44));
  });
}

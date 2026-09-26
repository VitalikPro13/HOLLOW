import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/support_glyph.dart';

const _peer = 'peer_support_chip_0001';

SupportCredInfo _mark(String item, String title) => SupportCredInfo(
      cred: SupportCred(item: item, parts: const {}, badge: true),
      artist: 'VitalikPro13',
      title: title,
    );

Future<void> _pump(WidgetTester tester, List<SupportCredInfo> marks) =>
    tester.pumpWidget(ProviderScope(
      overrides: [
        supportMarkInfosProvider(_peer).overrideWith((_) => marks),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: Center(child: SupportMarksChip(peerId: _peer)),
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
}

// Equal-width choice rows never cut a label short: on a narrow phone they
// stack. The archive export dialog on an iPhone 13 mini read "Full",
// "Images o..." and "Message...".
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';

Future<void> _openExport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showExportArchiveDialog(
              context,
              isDm: true,
              peerId: 'peer',
              name: 'AnonListen',
              messageCount: 174,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

bool _cut(WidgetTester tester, String label) =>
    tester.renderObject<RenderParagraph>(find.text(label)).didExceedMaxLines;

void main() {
  const labels = ['Full', 'Images only', 'Messages only'];

  testWidgets('a narrow phone stacks the choices, every label whole',
      (tester) async {
    await _openExport(tester, const Size(375, 812));
    for (final label in labels) {
      expect(_cut(tester, label), isFalse, reason: '"$label" was cut short');
    }
    final tops = {
      for (final label in labels) tester.getTopLeft(find.text(label)).dy,
    };
    expect(tops.length, labels.length, reason: 'one choice per line');
  });

  testWidgets('labels that fit share one line evenly', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: HollowChipTabs<int>(
              expand: true,
              selected: 0,
              onSelected: (_) {},
              tabs: const [
                HollowChipTab(value: 0, label: 'A'),
                HollowChipTab(value: 1, label: 'B'),
              ],
            ),
          ),
        ),
      ),
    ));
    final a = tester.getRect(find.ancestor(
        of: find.text('A'), matching: find.byType(Semantics)).first);
    final b = tester.getRect(find.ancestor(
        of: find.text('B'), matching: find.byType(Semantics)).first);
    expect(a.width, closeTo(b.width, 0.01));
    expect(a.top, b.top);
  });
}

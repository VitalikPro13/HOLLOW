// #159: hold a sticker, emoji or GIF in the picker to see it magnified, so
// stickers that differ only in a speech bubble can be told apart before one is
// sent. A released hold must never send; a short tap sends as before.
import 'package:flutter/gestures.dart' show PointerDeviceKind, kLongPressTimeout, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/expression_preview.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart' show GifMenuItem;
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

final _sent = <String>[];
final _acted = <String>[];

Widget _cell(String name) => SizedBox(
      width: 64,
      height: 64,
      child: ExpressionPreviewTarget(
        data: ExpressionPreviewData(
          label: name,
          media: (_) => SizedBox.square(
              dimension: kExpressionPreviewMedia, child: Text('big $name')),
        ),
        onSend: () => _sent.add(name),
        actions: (_) => [
          GifMenuItem(
            icon: LucideIcons.bookmarkPlus,
            label: 'Save $name',
            onTap: () => _acted.add(name),
          ),
        ],
        child: HollowPressable(
          onTap: () => _sent.add(name),
          semanticLabel: 'Insert sticker $name',
          child: Text('cell $name'),
        ),
      ),
    );

Future<void> _pump(WidgetTester tester) async {
  _sent.clear();
  _acted.clear();
  tester.view.physicalSize = const Size(600, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 440,
            child: ExpressionPreviewArea(
              child: Row(children: [_cell('cat'), _cell('dog')]),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

final _preview = find.textContaining('big ');

void main() {
  tearDown(() => debugExpressionPreviewTouch = null);

  group('desktop', () {
    setUp(() => debugExpressionPreviewTouch = false);

    testWidgets('a short click sends and shows nothing', (tester) async {
      await _pump(tester);
      await tester.tap(find.text('cell cat'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(_sent, ['cat']);
      expect(_preview, findsNothing);
    });

    testWidgets('holding the button previews, letting go closes and sends '
        'nothing', (tester) async {
      await _pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('cell cat')),
          kind: PointerDeviceKind.mouse);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);

      // Sliding onto a neighbour previews it instead, without letting go.
      await g.moveTo(tester.getCenter(find.text('cell dog')));
      await tester.pump();
      expect(find.text('big dog'), findsOneWidget);
      expect(find.text('big cat'), findsNothing);

      await g.up();
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      expect(_sent, isEmpty, reason: 'a released hold never sends');
    });

    testWidgets('right-click offers Preview, which stays until dismissed',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('cell cat'),
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(find.text('Save cat'), findsOneWidget,
          reason: 'the cell keeps its own actions');
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);
      expect(_sent, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
    });

    testWidgets('Send under a kept preview sends that one and closes it',
        (tester) async {
      await _pump(tester);
      await tester.tap(find.text('cell dog'),
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(_sent, ['dog']);
      expect(_preview, findsNothing);
    });
  });

  group('touch', () {
    setUp(() => debugExpressionPreviewTouch = true);

    testWidgets('a long press keeps the preview with the actions under it',
        (tester) async {
      await _pump(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('cell cat')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);
      expect(find.text('Send'), findsNothing,
          reason: 'while the finger is down it is only a picture');

      await g.moveTo(tester.getCenter(find.text('cell dog')));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(_sent, isEmpty, reason: 'a released hold never sends');
      expect(find.text('big dog'), findsOneWidget,
          reason: 'the last one slid onto is the one kept');
      expect(find.text('Send'), findsOneWidget);
      expect(
          tester
              .getSize(find
                  .ancestor(
                      of: find.text('Send'),
                      matching: find.byType(HollowPressable))
                  .first)
              .height,
          greaterThanOrEqualTo(44),
          reason: 'a finger-sized row');
      expect(find.text('Save dog'), findsOneWidget,
          reason: 'a phone has no right-click: the actions live here');

      await tester.tap(find.text('Save dog'));
      await tester.pumpAndSettle();
      expect(_acted, ['dog']);
      expect(_preview, findsNothing);
    });

    testWidgets('a tap outside a kept preview closes it', (tester) async {
      await _pump(tester);
      await tester.longPress(find.text('cell cat'));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      expect(_sent, isEmpty);
    });
  });

  testWidgets('bytes that land while previewing show in the preview',
      (tester) async {
    debugExpressionPreviewTouch = false;
    final media = ValueNotifier<String>('still');
    addTearDown(media.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: ExpressionPreviewArea(
          child: ValueListenableBuilder<String>(
            valueListenable: media,
            builder: (_, value, _) => ExpressionPreviewTarget(
              data: ExpressionPreviewData(
                  label: 'cat', media: (_) => Text('shown $value')),
              onSend: () {},
              child: const SizedBox(
                  width: 64, height: 64, child: ColoredBox(color: Color(0xff336699))), // design-ignore: test fixture
            ),
          ),
        ),
      ),
    ));
    final g = await tester.startGesture(
        tester.getCenter(find.byType(ExpressionPreviewTarget)),
        kind: PointerDeviceKind.mouse);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('shown still'), findsOneWidget);
    // The cell rebuilds with its animated bytes while the preview is open.
    media.value = 'animated';
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('shown animated'), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
  });
}

// #159: hold a sticker, emoji or GIF in the picker to see it magnified, so
// stickers that differ only in a speech bubble can be told apart before one is
// sent. A released hold must never send; a short tap sends as before.
import 'package:flutter/gestures.dart' show PointerDeviceKind, kLongPressTimeout, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/expression_preview.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart' show GifMenuItem;
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

final _sent = <String>[];
final _acted = <String>[];

Widget _cell(String name) => SizedBox(
      key: ValueKey(name),
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

Future<void> _pump(WidgetTester tester,
    {ValueNotifier<List<String>>? names, FocusNode? focus,
    List<String>? escapes}) async {
  _sent.clear();
  _acted.clear();
  final cells = names ?? ValueNotifier(const ['cat', 'dog']);
  tester.view.physicalSize = const Size(600, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(),
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HollowThemeData.dark(),
      home: Scaffold(
        // Stands in for what has focus under the picker, an edit box say.
        body: Focus(
          focusNode: focus,
          autofocus: true,
          onKeyEvent: (_, e) {
            if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
              escapes?.add('the focused widget');
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Center(
            child: SizedBox(
              width: 360,
              height: 440,
              child: ExpressionPreviewArea(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: cells,
                  builder: (_, list, _) =>
                      Row(children: [for (final n in list) _cell(n)]),
                ),
              ),
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

    // #159 review: the peek belongs to the picker, so a held cell that is
    // rebuilt away (GIF search results landing, a wheel scroll in the lazy
    // grid) sent no end, and the peek stayed over the picker for good.
    testWidgets('a held cell that leaves the grid takes its peek with it',
        (tester) async {
      final names = ValueNotifier<List<String>>(['cat', 'dog']);
      addTearDown(names.dispose);
      await _pump(tester, names: names);
      final g = await tester.startGesture(
          tester.getCenter(find.text('cell cat')),
          kind: PointerDeviceKind.mouse);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);

      names.value = ['eel', 'fox'];
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      expect(OverlayHosts.openCount, 0);
      await g.up();
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      expect(_sent, isEmpty);
    });

    testWidgets('the app lock clears a peek in the same frame', (tester) async {
      await _pump(tester);
      final g = await tester.startGesture(
          tester.getCenter(find.text('cell cat')),
          kind: PointerDeviceKind.mouse);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);
      expect(OverlayHosts.openCount, 1, reason: 'a peek is a raw host too');

      OverlayHosts.dismissAll();
      await tester.pump();
      expect(_preview, findsNothing,
          reason: 'a peek left up would paint over the lock cover');
      await g.up();
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
    });

    // #159 review: a HardwareKeyboard handler runs beside focus, so the
    // Escape that closed the preview also reached the edit box under it (and
    // the media viewer's own handler closed the viewer).
    testWidgets('Escape on a kept preview does not also reach the focused '
        'widget', (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      final escapes = <String>[];
      await _pump(tester, focus: focus, escapes: escapes);
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.tap(find.text('cell cat'),
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);
      expect(OverlayHosts.keysHeld, isTrue,
          reason: 'screen-level key handlers stand aside');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(focus.hasPrimaryFocus, isTrue,
          reason: 'the keyboard is back at once, not after the exit animation');
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      expect(escapes, isEmpty,
          reason: 'Escape closes only the innermost layer');
      expect(OverlayHosts.keysHeld, isFalse);
      expect(focus.hasPrimaryFocus, isTrue,
          reason: 'the keyboard goes back where it was');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(escapes, ['the focused widget']);
    });

    testWidgets('a kept preview can be closed by a screen reader',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      await tester.tap(find.text('cell cat'),
          buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      final barrier = find.bySemanticsLabel('Close preview');
      expect(barrier, findsOneWidget);
      tester.semantics.performAction(
          find.semantics.byLabel('Close preview'), SemanticsAction.dismiss);
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      handle.dispose();
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

    testWidgets('a cell slid onto that leaves the grid takes the peek with it',
        (tester) async {
      final names = ValueNotifier<List<String>>(['cat', 'dog']);
      addTearDown(names.dispose);
      await _pump(tester, names: names);
      final g = await tester.startGesture(tester.getCenter(find.text('cell cat')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      await g.moveTo(tester.getCenter(find.text('cell dog')));
      await tester.pump();
      expect(find.text('big dog'), findsOneWidget);

      names.value = ['cat', 'eel'];
      await tester.pumpAndSettle();
      expect(_preview, findsNothing);
      await g.up();
      await tester.pumpAndSettle();
      expect(_preview, findsNothing,
          reason: 'nothing is kept for a cell that is gone');
      expect(OverlayHosts.openCount, 0);
      expect(_sent, isEmpty);
    });

    // A phone has no Escape to catch, and focus handed back to the composer
    // would raise the keyboard over the sheet.
    testWidgets('a kept preview leaves the keyboard focus where it is',
        (tester) async {
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await _pump(tester, focus: focus);
      await tester.longPress(find.text('cell cat'));
      await tester.pumpAndSettle();
      expect(find.text('big cat'), findsOneWidget);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(OverlayHosts.keysHeld, isFalse);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(focus.hasPrimaryFocus, isTrue);
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

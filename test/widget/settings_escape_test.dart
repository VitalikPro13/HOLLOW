import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/settings/settings_place_frame.dart';

// The close control promises "(Esc)": Escape closes a settings place wherever focus
// sits, unless something above the place takes the key (g13).

Widget _app(Widget body) => ProviderScope(
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: body),
      ),
    );

SettingsPlaceFrame _frame(VoidCallback onClose, {Widget? page, Widget? bottomBar}) =>
    SettingsPlaceFrame(
      rail: const SizedBox(width: 200),
      page: page ?? const SizedBox(height: 40),
      closeLabel: 'Close',
      closeTooltip: 'Close server settings (Esc)',
      onClose: onClose,
      bottomBar: bottomBar,
    );

void main() {
  testWidgets('Escape closes settings while a field has focus', (tester) async {
    var closed = 0;
    final controller = TextEditingController();
    final focus = FocusNode();
    await tester.pumpWidget(_app(_frame(
      () => closed++,
      page: HollowTextField(controller: controller, focusNode: focus, hintText: 'Up to 512'),
    )));
    await tester.pumpAndSettle();
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('Escape closes settings while focus sits outside the place', (tester) async {
    var closed = 0;
    final outside = FocusNode();
    await tester.pumpWidget(_app(Row(
      children: [
        Focus(focusNode: outside, child: const SizedBox(width: 40, height: 40)),
        Expanded(child: _frame(() => closed++)),
      ],
    )));
    await tester.pumpAndSettle();
    outside.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('Escape closes settings once the focused save bar is gone', (tester) async {
    var closed = 0;
    final save = FocusNode();
    var showBar = true;
    late StateSetter setBar;
    await tester.pumpWidget(_app(StatefulBuilder(builder: (context, setState) {
      setBar = setState;
      return _frame(
        () => closed++,
        bottomBar: showBar ? Focus(focusNode: save, child: const SizedBox(height: 40)) : null,
      );
    })));
    await tester.pumpAndSettle();
    save.requestFocus();
    await tester.pump();
    expect(save.hasFocus, isTrue);
    setBar(() => showBar = false);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('Escape over a route above the place leaves the place open', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_app(_frame(() => closed++)));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => const Focus(autofocus: true, child: SizedBox.expand()),
    ));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 0);
  });

  testWidgets('Escape a focused widget outside takes never closes the place', (tester) async {
    var closed = 0;
    var taken = 0;
    final outside = FocusNode(onKeyEvent: (_, event) {
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
        taken++;
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    });
    await tester.pumpWidget(_app(Row(
      children: [
        Focus(focusNode: outside, child: const SizedBox(width: 40, height: 40)),
        Expanded(child: _frame(() => closed++)),
      ],
    )));
    await tester.pumpAndSettle();
    outside.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect((taken, closed), (1, 0));
  });

  testWidgets('Escape over marked text cancels the conversion, not settings',
      (tester) async {
    var closed = 0;
    final controller = TextEditingController();
    final focus = FocusNode();
    await tester.pumpWidget(_app(_frame(
      () => closed++,
      page: HollowTextField(controller: controller, focusNode: focus, hintText: 'Name'),
    )));
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byType(EditableText));
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'にほんご',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 0, end: 4),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 0);

    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '日本語',
      selection: TextSelection.collapsed(offset: 3),
    ));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
  }, variant: const TargetPlatformVariant(
      {TargetPlatform.macOS, TargetPlatform.linux}));
}

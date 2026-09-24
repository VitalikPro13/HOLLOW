import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/mobile_keyboard_panel.dart';

/// The phone composer's dock: the expression panel takes the keyboard's place
/// at the keyboard's height, so the composer never moves during the swap.
void main() {
  const composerKey = Key('composer');
  const panelKey = Key('panel');

  late FocusNode focus;
  late ValueNotifier<bool> open;

  setUp(() {
    debugForgetKeyboardHeight();
    focus = FocusNode();
    open = ValueNotifier(false);
  });
  tearDown(() {
    focus.dispose();
    open.dispose();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                const Expanded(child: SizedBox.expand()),
                TextField(key: composerKey, focusNode: focus),
                ValueListenableBuilder<bool>(
                  valueListenable: open,
                  builder: (_, isOpen, _) => MobileKeyboardPanelDock(
                    open: isOpen,
                    keyboardFocus: focus,
                    panelBuilder: (_) => const SizedBox.expand(key: panelKey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  double screenHeight(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  void setKeyboard(WidgetTester tester, double logical) {
    tester.view.viewInsets = FakeViewPadding(
      bottom: logical * tester.view.devicePixelRatio,
    );
  }

  double composerBottom(WidgetTester tester) =>
      tester.getBottomLeft(find.byKey(composerKey)).dy;

  testWidgets('the panel takes the keyboard height, so the composer stays',
      (tester) async {
    addTearDown(tester.view.reset);
    await pumpHost(tester);
    setKeyboard(tester, 300);
    await tester.pump();
    final withKeyboard = composerBottom(tester);
    expect(withKeyboard, closeTo(screenHeight(tester) - 300, 0.5));

    // Smiley: the keyboard goes down behind the panel.
    open.value = true;
    await tester.pump();
    setKeyboard(tester, 120);
    await tester.pump();
    expect(composerBottom(tester), closeTo(withKeyboard, 0.5));
    setKeyboard(tester, 0);
    await tester.pump();
    expect(composerBottom(tester), closeTo(withKeyboard, 0.5));
    expect(find.byKey(panelKey), findsOneWidget);
  });

  testWidgets('back to the keyboard: the panel waits until it is covered',
      (tester) async {
    addTearDown(tester.view.reset);
    await pumpHost(tester);
    setKeyboard(tester, 300);
    await tester.pump();
    setKeyboard(tester, 0);
    open.value = true;
    await tester.pump();
    final withPanel = composerBottom(tester);

    focus.requestFocus();
    open.value = false;
    await tester.pump();
    expect(find.byKey(panelKey), findsOneWidget);
    expect(composerBottom(tester), closeTo(withPanel, 0.5));
    setKeyboard(tester, 150);
    await tester.pump();
    expect(composerBottom(tester), closeTo(withPanel, 0.5));
    setKeyboard(tester, 300);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(panelKey), findsNothing);
    expect(composerBottom(tester), closeTo(withPanel, 0.5));
  });

  testWidgets('closing without the keyboard collapses at once',
      (tester) async {
    addTearDown(tester.view.reset);
    await pumpHost(tester);
    open.value = true;
    await tester.pump();
    // No keyboard seen yet: a share of the screen.
    expect(
      tester.getSize(find.byType(MobileKeyboardPanelDock)).height,
      closeTo(screenHeight(tester) * 0.4, 0.5),
    );
    open.value = false;
    await tester.pump();
    expect(find.byKey(panelKey), findsNothing);
  });

  testWidgets('a hardware keyboard: the waiting panel gives up',
      (tester) async {
    addTearDown(tester.view.reset);
    await pumpHost(tester);
    open.value = true;
    await tester.pump();
    focus.requestFocus();
    open.value = false;
    await tester.pump();
    expect(find.byKey(panelKey), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(panelKey), findsNothing);
  });
}

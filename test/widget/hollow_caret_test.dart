import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';

/// The caret every Hollow input draws: no taller than the glyphs, never on
/// top of the last one, on every platform, and the field still behaves like
/// its platform (menus, what it hosts).
void main() {
  setUp(() => EditableText.debugDeterministicCursor = true);
  tearDown(() => EditableText.debugDeterministicCursor = false);

  TargetPlatform? seen;

  Future<RenderEditable> pump(WidgetTester tester, TargetPlatform platform,
      {double dpr = 2}) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = Size(400 * dpr, 200 * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    final controller = TextEditingController(text: 'extend');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark().copyWith(platform: platform),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(8),
          child: HollowTextField(
            controller: controller,
            autofocus: true,
            prefixIcon: Builder(builder: (context) {
              seen = Theme.of(context).platform;
              return const SizedBox(width: 16, height: 16);
            }),
          ),
        ),
      ),
    ));
    await tester.pump();
    controller.selection = const TextSelection.collapsed(offset: 6);
    await tester.pump();
    return tester.state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
  }

  Future<void> openMenu(WidgetTester tester) async {
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    state.userUpdateTextEditingValue(
        state.textEditingValue.copyWith(
            selection: const TextSelection(baseOffset: 0, extentOffset: 6)),
        SelectionChangedCause.toolbar);
    await tester.pump();
    state.showToolbar();
    await tester.pumpAndSettle();
  }

  // The field's own selection controls build this menu on every platform.
  final materialMenu = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_TextSelectionControlsToolbar');

  for (final platform in TargetPlatform.values) {
    testWidgets('${platform.name}: the caret sits after the last glyph',
        (tester) async {
      final editable = await pump(tester, platform);
      final caret = editable.getLocalRectForCaret(
          const TextPosition(offset: 6));
      final lastGlyph = editable
          .getBoxesForSelection(
              const TextSelection(baseOffset: 5, extentOffset: 6))
          .single
          .toRect();
      expect(caret.left, greaterThanOrEqualTo(lastGlyph.right - 0.5),
          reason: 'caret $caret overlaps the last glyph $lastGlyph');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('${platform.name}: the caret is as tall as the glyphs',
        (tester) async {
      final editable = await pump(tester, platform);
      final caret = editable.getLocalRectForCaret(
          const TextPosition(offset: 6));
      final glyphs = HollowCaret.height(
          HollowTypography.body, TextScaler.noScaling);
      expect(caret.height, closeTo(glyphs, 0.5));
      expect(caret.height, lessThan(editable.preferredLineHeight));
      expect(caret.top, greaterThanOrEqualTo(-0.5));
      expect(caret.bottom, lessThanOrEqualTo(editable.preferredLineHeight + 0.5));
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('the caret grows with the text size', (tester) async {
    final small =
        HollowCaret.height(HollowTypography.body, TextScaler.noScaling);
    final big = HollowCaret.height(
        HollowTypography.body, const TextScaler.linear(2));
    expect(big, closeTo(small * 2, 0.01));
  });

  testWidgets('macOS: the menu is unchanged and hosts see the Mac',
      (tester) async {
    await pump(tester, TargetPlatform.macOS);
    expect(seen, TargetPlatform.macOS);
    await openMenu(tester);
    await tester.pumpAndSettle();
    expect(materialMenu, findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS: the menu is unchanged and hosts see iOS',
      (tester) async {
    await pump(tester, TargetPlatform.iOS);
    expect(seen, TargetPlatform.iOS);
    await openMenu(tester);
    await tester.pumpAndSettle();
    expect(materialMenu, findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows: the menu and hosts are untouched', (tester) async {
    await pump(tester, TargetPlatform.windows);
    expect(seen, TargetPlatform.windows);
    await openMenu(tester);
    await tester.pumpAndSettle();
    expect(materialMenu, findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}

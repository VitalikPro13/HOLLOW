import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard: a context menu must not be reachable by right click alone.
///
/// Right click is a POINTER route. Several of these menus own actions that
/// live nowhere else in the UI — folder membership, "mark all DMs as read",
/// the per-peer voice volume — so a menu wired to a bare `onSecondaryTapUp`
/// is an action a keyboard or screen-reader user simply cannot perform.
///
/// [ContextMenuTarget] (`hollow_menu.dart`) is the wrapper that adds the other
/// two routes: Menu / Shift+F10 while the control is focused, and a "Show
/// menu" custom semantics action. It also handles the right click itself, so
/// using it is strictly less code than not.
///
/// The rule this enforces: no `onSecondaryTapUp` handler may call a public
/// `show*Menu(` opener directly. Secondary tap for anything else (dismissing a
/// picker, a debug hook) is untouched, and so are the picker-internal
/// `_show*Menu` helpers, which already carry a long-press route of their own
/// for touch.
void main() {
  test('every context menu is opened through ContextMenuTarget', () {
    final uiDir = Directory('lib/src/ui');
    expect(uiDir.existsSync(), isTrue,
        reason: 'expected to run from the project root (lib/src/ui missing)');

    // `onSecondaryTapUp: ...` up to the end of its handler, roughly: stop at
    // the next property that starts a sibling argument. Matching the opener
    // anywhere inside that span is enough — a menu opener is never incidental.
    final secondaryTap = RegExp(r'onSecondaryTap(Up|Down)?\s*:');
    final opener = RegExp(r'\bshow[A-Za-z]*Menu\s*\(');

    final offenders = <String>[];
    for (final entity in uiDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsStringSync().split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!secondaryTap.hasMatch(lines[i])) continue;
        // Look at the handler's first few lines: an opener called from a
        // secondary tap is always right there.
        final end = (i + 6).clamp(0, lines.length);
        final span = lines.sublist(i, end).join('\n');
        if (opener.hasMatch(span)) {
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }

    if (offenders.isNotEmpty) {
      fail('\nA context menu is opened straight from onSecondaryTapUp:\n\n'
          '${offenders.map((o) => '  $o').join('\n')}\n\n'
          'That makes it a mouse-only action. Wrap the widget in '
          '`ContextMenuTarget(onOpen: (anchor) => show...Menu(..., anchor: '
          'anchor))` instead — it handles the right click AND adds the '
          'Menu / Shift+F10 and screen-reader routes.\n');
    }
  });

  test('ContextMenuTarget still carries both non-pointer routes', () {
    final source =
        File('lib/src/ui/components/hollow_menu.dart').readAsStringSync();
    expect(source, contains('LogicalKeyboardKey.contextMenu'),
        reason: 'the Menu key route was removed from ContextMenuTarget');
    expect(source, contains('LogicalKeyboardKey.f10'),
        reason: 'the Shift+F10 route was removed from ContextMenuTarget');
    expect(source, contains('CustomSemanticsAction'),
        reason: 'the screen-reader route was removed from ContextMenuTarget');
  });
}

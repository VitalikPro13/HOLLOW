import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CI guard: a `showHollowMenu` builder must not name its ref `ref`.
///
/// `showHollowMenu(builder: (context, ref) => ...)` hands you a [WidgetRef]
/// owned by the MENU ROUTE's `Consumer`. The menu closes before its rows run
/// their actions (deliberately — an action that opens a dialog must not race
/// the pop), so by the time an action executes that ref is disposed.
///
/// Naming it `ref` shadows the caller's own longer-lived ref, so every action
/// closure in the builder silently captures the doomed one. The failure is
/// invisible: `ref.read(...)` throws inside an async gap, the exception goes to
/// the zone handler, and the user just sees a button that does nothing. It cost
/// a full test round on issue #61 — "Create category does nothing", "Remove
/// label requirement does nothing", while every ref-free row still worked.
///
/// Rule: name the builder's ref `menuRef` (or `_`) and use it ONLY for
/// `watch`-ing display state. Actions capture the caller's `ref`.
void main() {
  test('showHollowMenu builders do not shadow the caller ref', () {
    final uiDir = Directory('lib/src/ui');
    expect(uiDir.existsSync(), isTrue,
        reason: 'expected to run from the project root (lib/src/ui missing)');

    // `builder:` line of a menu, with the second parameter named exactly `ref`.
    final offending = RegExp(r'builder:\s*\(\s*\w+\s*,\s*ref\s*\)');

    final offenders = <String>[];
    for (final entity in uiDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      // Only files that actually open menus can hit this trap.
      if (!source.contains('showHollowMenu(')) continue;

      final lines = source.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!offending.hasMatch(lines[i])) continue;
        // Riverpod's own `Consumer(builder: (context, ref, _))` is three-arg
        // and legitimate; the menu builder is two-arg.
        if (RegExp(r'builder:\s*\(\s*\w+\s*,\s*ref\s*,').hasMatch(lines[i])) {
          continue;
        }
        offenders.add('${entity.path}:${i + 1}');
      }
    }

    if (offenders.isNotEmpty) {
      fail('\nA showHollowMenu builder names its ref `ref`, shadowing the '
          "caller's:\n\n"
          '${offenders.map((o) => '  $o').join('\n')}\n\n'
          'The builder ref belongs to the menu route and is DISPOSED by the '
          'time a row\'s action runs, so the action fails silently.\n'
          'Rename it to `menuRef` (watch-only) and let actions capture the '
          "caller's `ref`.\n");
    }
  });
}

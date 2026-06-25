import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Keyboard-focus CI guard (a11y Phase 2.6).
///
/// Phase 2.6 makes the WHOLE app keyboard-operable from a single chokepoint:
/// every interactive surface funnels through [HollowPressable] /
/// [HollowButton] / [HollowToggle], and each of those wraps its content in a
/// [HollowFocusRing] (which supplies Tab-focusability + Enter/Space activation
/// + the focus indicator). Because the leverage is centralised, the RISK is
/// centralised too: if a refactor drops `HollowFocusRing` from any of the three
/// components, all ~645 call sites silently lose keyboard access at once and no
/// per-call-site test would notice.
///
/// This static source scan is that tripwire. It runs in milliseconds (no FFI /
/// rendering) and fails the build if a core component stops importing+using
/// `HollowFocusRing`. The behavioural proof that the wiring actually works
/// lives in `test/widget/focus_traversal_test.dart` (Tab focuses, Enter/Space
/// activate once); this guard just stops the wiring from quietly disappearing.
///
/// It also re-affirms the design-token invariant: `HollowTheme` must keep a
/// `focusRing` field (the ring colour), so nobody removes it as "unused".
void main() {
  test('core interactive components keep their HollowFocusRing wiring', () {
    const components = [
      'lib/src/ui/components/hollow_pressable.dart',
      'lib/src/ui/components/hollow_button.dart',
      'lib/src/ui/components/hollow_toggle.dart',
    ];

    final failures = <String>[];

    for (final path in components) {
      final file = File(path);
      if (!file.existsSync()) {
        failures.add('$path — file missing (component moved/renamed?)');
        continue;
      }
      final src = file.readAsStringSync();

      final imports = src.contains("components/hollow_focus_ring.dart");
      // Used as a widget somewhere in the build tree.
      final uses = RegExp(r'\bHollowFocusRing\s*\(').hasMatch(src);

      if (!imports || !uses) {
        failures.add('$path — does NOT wire HollowFocusRing '
            '(import: $imports, used: $uses). Phase 2.6 keyboard focus relies '
            'on every interactive control wrapping its content in a '
            'HollowFocusRing. Re-add it, or this control will not be '
            'keyboard-focusable / activatable.');
      }
    }

    if (failures.isNotEmpty) {
      fail('\nKeyboard-focus chokepoint broken:\n\n  ${failures.join('\n\n  ')}'
          '\n\nSee test/widget/focus_traversal_test.dart for the behaviour '
          'this protects.');
    }
  });

  test('HollowTheme keeps the focusRing design token', () {
    final src = File('lib/src/theme/hollow_theme.dart').readAsStringSync();
    expect(
      RegExp(r'\bfinal\s+Color\s+focusRing\b').hasMatch(src),
      isTrue,
      reason: 'HollowTheme.focusRing is the focus-ring colour token (a11y '
          '2.6). Removing it leaves HollowFocusRing with no colour to paint. '
          'If you are renaming it, update hollow_focus_ring.dart too.',
    );
  });
}

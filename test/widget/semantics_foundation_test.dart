import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';

/// Phase 2.1 — verify the three core interactive components expose proper
/// semantics to VoiceOver / Voice Control, AND that wrapping a GestureDetector
/// in Semantics(onTap:) does NOT cause a physical tap to fire the callback
/// twice (the double-fire regression the implementation plan flags).
///
/// These run headless (~1s) and stand in for the device screen-reader pass on
/// the foundation itself; the long-tail label correctness still needs Vitalik's
/// real-device VoiceOver/TalkBack sweep.
Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('HollowButton semantics', () {
    testWidgets('exposes button role + text-child name', (tester) async {
      await tester.pumpWidget(
        _host(HollowButton.filled(onPressed: () {}, child: const Text('Save'))),
      );

      final node = tester.getSemantics(find.text('Save'));
      expect(node, matchesSemantics(label: 'Save', isButton: true, hasTapAction: true, hasEnabledState: true, isEnabled: true));
    });

    testWidgets('semanticLabel overrides for icon-only button', (tester) async {
      await tester.pumpWidget(
        _host(HollowButton.ghost(
          onPressed: () {},
          semanticLabel: 'Close',
          child: const Icon(Icons.close),
        )),
      );

      expect(
        find.bySemanticsLabel('Close'),
        findsOneWidget,
        reason: 'icon-only button must carry its semanticLabel',
      );
    });

    testWidgets('disabled button is not enabled in semantics', (tester) async {
      await tester.pumpWidget(
        _host(const HollowButton.filled(onPressed: null, child: Text('Save'))),
      );

      final node = tester.getSemantics(find.text('Save'));
      // Disabled: still a button, but not enabled and no tap action.
      expect(node, matchesSemantics(label: 'Save', isButton: true, hasEnabledState: true, isEnabled: false));
    });

    testWidgets('physical tap fires onPressed exactly once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(HollowButton.filled(
          onPressed: () => taps++,
          child: const Text('Tap me'),
        )),
      );

      await tester.tap(find.text('Tap me'));
      await tester.pump();
      expect(taps, 1, reason: 'GestureDetector under Semantics(onTap:) must not double-fire on a real tap');
    });

    testWidgets('semantic tap action fires onPressed exactly once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(HollowButton.filled(
          onPressed: () => taps++,
          child: const Text('Tap me'),
        )),
      );

      final handle = tester.ensureSemantics();
      final id = tester.getSemantics(find.text('Tap me')).id;
      tester.binding.pipelineOwner.semanticsOwner!
          .performAction(id, SemanticsAction.tap);
      await tester.pump();
      expect(taps, 1, reason: 'assistive-tech activation must invoke onPressed once');
      handle.dispose();
    });
  });

  group('HollowToggle semantics', () {
    testWidgets('exposes toggled state (on)', (tester) async {
      await tester.pumpWidget(
        _host(HollowToggle(
          value: true,
          onChanged: (_) {},
          semanticLabel: 'Reduce motion',
        )),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Reduce motion'));
      expect(node, matchesSemantics(
        label: 'Reduce motion',
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ));
    });

    testWidgets('exposes toggled state (off)', (tester) async {
      await tester.pumpWidget(
        _host(HollowToggle(
          value: false,
          onChanged: (_) {},
          semanticLabel: 'Reduce motion',
        )),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Reduce motion'));
      expect(node, matchesSemantics(
        label: 'Reduce motion',
        hasToggledState: true,
        isToggled: false,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ));
    });

    testWidgets('physical tap flips value exactly once', (tester) async {
      var changes = 0;
      bool? last;
      await tester.pumpWidget(
        _host(HollowToggle(
          value: false,
          onChanged: (v) {
            changes++;
            last = v;
          },
          semanticLabel: 'Reduce motion',
        )),
      );

      await tester.tap(find.bySemanticsLabel('Reduce motion'));
      await tester.pump();
      expect(changes, 1, reason: 'toggle must not double-fire on a real tap');
      expect(last, true);
    });
  });

  group('HollowPressable semantics', () {
    testWidgets('button role + label when interactive', (tester) async {
      await tester.pumpWidget(
        _host(HollowPressable(
          onTap: () {},
          semanticLabel: 'Settings',
          child: const Icon(Icons.settings),
        )),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Settings'));
      expect(node, matchesSemantics(
        label: 'Settings',
        isButton: true,
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ));
    });

    testWidgets('semanticButton:false drops button role but stays tappable',
        (tester) async {
      await tester.pumpWidget(
        _host(HollowPressable(
          onTap: () {},
          semanticButton: false,
          semanticLabel: 'Conversation row',
          child: const SizedBox(width: 100, height: 40),
        )),
      );

      final node = tester.getSemantics(find.bySemanticsLabel('Conversation row'));
      // Not a button, but the tap action is present so Voice Control can invoke.
      // (Semantics(enabled:) adds the enabled flags even without the button role.)
      expect(node, matchesSemantics(
        label: 'Conversation row',
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ));
      expect(node.hasFlag(SemanticsFlag.isButton), isFalse,
          reason: 'row should NOT announce the button role');
    });

    testWidgets('physical tap fires onTap exactly once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(HollowPressable(
          onTap: () => taps++,
          semanticLabel: 'Settings',
          child: const Icon(Icons.settings),
        )),
      );

      await tester.tap(find.bySemanticsLabel('Settings'));
      await tester.pump();
      expect(taps, 1, reason: 'pressable must not double-fire on a real tap');
    });

    testWidgets('non-interactive pressable exposes no tap action',
        (tester) async {
      await tester.pumpWidget(
        _host(const HollowPressable(
          onTap: null,
          child: Text('Static'),
        )),
      );

      final node = tester.getSemantics(find.text('Static'));
      expect(node, isNot(matchesSemantics(hasTapAction: true)));
    });
  });
}

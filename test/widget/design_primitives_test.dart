import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';

/// The design-language primitives (`reports/reference/HOLLOW_DESIGN_LANGUAGE.md`
/// section 4). These replace 46 local chip, pill, tag and badge classes plus
/// four section-header helpers, so the rules that made them one component are
/// asserted here rather than left to a reviewer's eye.
Future<HollowTheme> _pump(WidgetTester tester, Widget child,
    {bool light = false}) async {
  late HollowTheme hollow;
  await tester.pumpWidget(
    MaterialApp(
      theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
      home: Scaffold(
        body: Builder(builder: (context) {
          hollow = HollowTheme.of(context);
          return Center(child: child);
        }),
      ),
    ),
  );
  await tester.pump();
  return hollow;
}

BoxDecoration _decorationOf(WidgetTester tester, Finder finder) {
  final container = tester.widget<Container>(finder);
  return container.decoration! as BoxDecoration;
}

void main() {
  group('HollowBadge', () {
    testWidgets('states a fact and is not tappable', (tester) async {
      await _pump(tester, const HollowBadge('Owned'));

      expect(find.text('Owned'), findsOneWidget);
      // The whole point of the badge/chip split: a badge offers no gesture, so
      // nothing can be built on top of it that quietly becomes interactive.
      expect(
        find.descendant(
          of: find.byType(HollowBadge),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('a semantic kind carries its own colour, not just a tint',
        (tester) async {
      final hollow = await _pump(
        tester,
        const HollowBadge('Failed', kind: HollowBadgeKind.error),
      );

      final text = tester.widget<Text>(find.text('Failed'));
      expect(text.style!.color, hollow.error);
    });

    testWidgets('counts use tabular figures so they do not jog',
        (tester) async {
      await _pump(tester, const HollowBadge('12'));

      final text = tester.widget<Text>(find.text('12'));
      expect(
        text.style!.fontFeatures!.map((f) => f.feature),
        contains('tnum'),
      );
    });

    testWidgets('the mono kind is the console voice', (tester) async {
      await _pump(tester, const HollowBadge('a1b2', kind: HollowBadgeKind.mono));

      final text = tester.widget<Text>(find.text('a1b2'));
      expect(text.style!.fontFamily, HollowTypography.monoSmall.fontFamily);
    });
  });

  group('HollowChip', () {
    testWidgets('reports taps', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        HollowChip(label: 'Emotes', onTap: () => taps++),
      );

      await tester.tap(find.text('Emotes'));
      expect(taps, 1);
    });

    testWidgets('selected is an accent-muted fill with accent text, never a '
        'filled button', (tester) async {
      final hollow = await _pump(
        tester,
        HollowChip(label: 'Emotes', selected: true, onTap: () {}),
      );

      final text = tester.widget<Text>(find.text('Emotes'));
      expect(text.style!.color, hollow.accentText);

      final decoration = _decorationOf(
        tester,
        find.descendant(
          of: find.byType(HollowChip),
          matching: find.byType(Container),
        ),
      );
      expect(decoration.color, hollow.accentMuted);
      // Not textOnAccent: that would mean a solid accent fill, which is the
      // primary-button treatment and must never signal mere selection.
      expect(text.style!.color, isNot(hollow.textOnAccent));
    });

    testWidgets('selection changes colour, never weight', (tester) async {
      await _pump(tester, HollowChip(label: 'Emotes', onTap: () {}));
      final unselected = tester.widget<Text>(find.text('Emotes')).style!;

      await _pump(
        tester,
        HollowChip(label: 'Emotes', selected: true, onTap: () {}),
      );
      final selected = tester.widget<Text>(find.text('Emotes')).style!;

      // A weight change reflows the row under the pointer.
      expect(selected.fontWeight, unselected.fontWeight);
      expect(selected.fontSize, unselected.fontSize);
    });

    testWidgets('an unselected chip rests on no fill of its own',
        (tester) async {
      await _pump(tester, HollowChip(label: 'Emotes', onTap: () {}));

      final decoration = _decorationOf(
        tester,
        find.descendant(
          of: find.byType(HollowChip),
          matching: find.byType(Container),
        ),
      );
      // Never Colors.transparent, which is transparent BLACK and flashes dark
      // when it lerps to the hover colour.
      expect(decoration.color!.a, 0);
      expect(decoration.color, isNot(const Color(0x00000000)));
    });

    testWidgets('a label too long for its chip ellipsizes rather than '
        'overflowing', (tester) async {
      // A row of equal-width sub-tabs splits the width between them, so at a
      // large text scale the longest label has to give. It caught a real
      // overflow the first time the archive tabs became chips.
      await _pump(
        tester,
        SizedBox(
          width: 150,
          child: Row(
            children: [
              for (final label in ['DMs', 'Channels', 'Vault Files'])
                Expanded(
                  child: HollowChip(
                    label: label,
                    expand: true,
                    onTap: () {},
                  ),
                ),
            ],
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Text>(find.text('Vault Files')).overflow,
        TextOverflow.ellipsis,
      );
    });

    testWidgets('expand fills the width it is given', (tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 300,
          child: HollowChip(label: 'DMs', expand: true, onTap: () {}),
        ),
      );

      expect(tester.getSize(find.byType(HollowChip)).width, 300);
    });

    testWidgets('removable chips report the removal separately',
        (tester) async {
      var taps = 0;
      var removes = 0;
      await _pump(
        tester,
        HollowChip(
          label: 'Emotes',
          onTap: () => taps++,
          onRemove: () => removes++,
        ),
      );

      await tester.tap(find.byType(Icon));
      expect(removes, 1);
      expect(taps, 0);
    });
  });

  group('HollowButton', () {
    testWidgets('an icon passed as the child takes the variant foreground',
        (tester) async {
      // An icon-only button passes its glyph as the CHILD, not the icon slot.
      // The Shop's refresh button rendered in the ambient icon colour until
      // the button themed its child too, which read as a different control
      // sitting beside three ghost buttons.
      final hollow = await _pump(
        tester,
        HollowButton.ghost(
          onPressed: () {},
          semanticLabel: 'Refresh',
          child: const Icon(Icons.refresh),
        ),
      );

      final iconTheme = IconTheme.of(
        tester.element(find.byIcon(Icons.refresh)),
      );
      expect(iconTheme.color, hollow.accentText);
    });

    testWidgets('ghost and outline labels use accentText, never raw accent',
        (tester) async {
      for (final button in [
        HollowButton.ghost(onPressed: () {}, child: const Text('Cancel')),
        HollowButton.outline(onPressed: () {}, child: const Text('Cancel')),
      ]) {
        final hollow = await _pump(tester, button, light: true);
        final style = DefaultTextStyle.of(
          tester.element(find.text('Cancel')),
        ).style;
        expect(style.color, hollow.accentText);
        expect(style.color, isNot(hollow.accent));
      }
    });
  });

  group('HollowSectionHeader', () {
    testWidgets('has no leading icon and does not shout', (tester) async {
      await _pump(tester, const HollowSectionHeader('Your servers'));

      // The parameter does not exist; this proves nothing draws one anyway.
      expect(
        find.descendant(
          of: find.byType(HollowSectionHeader),
          matching: find.byType(Icon),
        ),
        findsNothing,
      );

      final text = tester.widget<Text>(find.text('Your servers'));
      expect(text.data, 'Your servers'); // sentence case, no toUpperCase
      expect(text.style!.letterSpacing, 0); // no tracked capitals
    });

    testWidgets('the count is the console voice at the quiet tier',
        (tester) async {
      final hollow = await _pump(
        tester,
        const HollowSectionHeader('Your servers', count: '12'),
      );

      final count = tester.widget<Text>(find.text('12'));
      expect(count.style!.fontFamily, HollowTypography.monoSmall.fontFamily);
      expect(count.style!.color, hollow.textTertiary);
    });

    testWidgets('a trailing action sits at the trailing edge', (tester) async {
      await _pump(
        tester,
        const HollowSectionHeader(
          'Your servers',
          action: Text('Add'),
        ),
      );

      final headerRight =
          tester.getBottomRight(find.byType(HollowSectionHeader)).dx;
      final actionRight = tester.getBottomRight(find.text('Add')).dx;
      expect(actionRight, closeTo(headerRight, 1));
    });
  });

  group('HollowEmptyState', () {
    testWidgets('says what is true now and can stand alone', (tester) async {
      await _pump(tester, const HollowEmptyState(title: 'No messages yet'));

      expect(find.text('No messages yet'), findsOneWidget);
    });

    testWidgets('description and one action are optional extras',
        (tester) async {
      var pressed = 0;
      await _pump(
        tester,
        HollowEmptyState(
          title: 'No servers yet',
          description: 'Join one with an invite link, or make your own.',
          action: TextButton(
            onPressed: () => pressed++,
            child: const Text('Create a server'),
          ),
        ),
      );

      expect(find.text('Join one with an invite link, or make your own.'),
          findsOneWidget);
      await tester.tap(find.text('Create a server'));
      expect(pressed, 1);
    });

    testWidgets('the glyph is the slot Holly takes, at 24', (tester) async {
      await _pump(
        tester,
        const HollowEmptyState(title: 'Nothing saved', glyph: Icons.inbox),
      );

      expect(tester.widget<Icon>(find.byType(Icon)).size, 24);
    });
  });

  group('HollowListRow', () {
    testWidgets('title, subtitle and trailing all render', (tester) async {
      await _pump(
        tester,
        const HollowListRow(
          title: 'Vitalik',
          subtitle: 'Online',
          trailing: HollowBadge('3'),
        ),
      );

      expect(find.text('Vitalik'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('the whole row is the hover and tap target, with no dead gap',
        (tester) async {
      var taps = 0;
      await _pump(
        tester,
        SizedBox(
          width: 400,
          child: HollowListRow(title: 'Vitalik', onTap: () => taps++),
        ),
      );

      // The far trailing edge, well past the text, still activates the row.
      final row = tester.getRect(find.byType(HollowListRow));
      await tester.tapAt(Offset(row.right - 4, row.center.dy));
      expect(taps, 1);
    });

    testWidgets('a row is actionable without claiming the button role',
        (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        HollowListRow(title: 'Vitalik', onTap: () {}),
      );

      expect(
        tester.getSemantics(find.text('Vitalik')),
        isSemantics(isButton: false, hasTapAction: true),
      );
      handle.dispose();
    });

    testWidgets('selection tints the row and its title', (tester) async {
      final hollow = await _pump(
        tester,
        HollowListRow(title: 'Vitalik', selected: true, onTap: () {}),
      );

      final title = tester.widget<Text>(find.text('Vitalik'));
      expect(title.style!.color, hollow.accentText);
    });
  });

  group('HollowSkeleton', () {
    testWidgets('holds the final geometry', (tester) async {
      await _pump(tester, const HollowSkeleton(width: 120, height: 16));

      final size = tester.getSize(find.byType(HollowSkeleton));
      expect(size.width, 120);
      expect(size.height, 16);
    });

    testWidgets('does not animate, so a long wait costs no frames',
        (tester) async {
      await _pump(tester, const HollowSkeleton(width: 120, height: 16));

      // A pending frame here would mean a Ticker is running: the skeleton
      // would ask the engine for a frame every vsync for the whole wait.
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('circle takes one diameter for both axes', (tester) async {
      await _pump(tester, const HollowSkeleton.circle(32));

      expect(tester.getSize(find.byType(HollowSkeleton)), const Size(32, 32));
    });
  });

  group('HollowDivider', () {
    testWidgets('is one pixel of the border colour and reserves nothing else',
        (tester) async {
      final hollow = await _pump(
        tester,
        const SizedBox(width: 200, child: HollowDivider()),
      );

      // Material's Divider defaults to a 16px tall band, which silently
      // changes the spacing of whatever it sits in. This is a line.
      expect(tester.getSize(find.byType(HollowDivider)).height, 1);

      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(HollowDivider),
          matching: find.byType(Container),
        ),
      );
      expect(container.color, hollow.border);
    });

    testWidgets('the vertical one is one pixel wide', (tester) async {
      await _pump(
        tester,
        const SizedBox(height: 200, child: HollowVerticalDivider()),
      );

      expect(tester.getSize(find.byType(HollowVerticalDivider)).width, 1);
    });
  });

  group('light theme', () {
    testWidgets('every primitive renders on the light theme too',
        (tester) async {
      await _pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const HollowBadge('Owned'),
            HollowChip(label: 'Emotes', onTap: () {}),
            const HollowSectionHeader('Your servers', count: '12'),
            const HollowListRow(title: 'Vitalik', subtitle: 'Online'),
            const HollowSkeleton(width: 120, height: 16),
            const SizedBox(width: 200, child: HollowDivider()),
          ],
        ),
        light: true,
      );

      expect(tester.takeException(), isNull);
    });
  });
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_key_combo.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';

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
 
    testWidgets('the hint and trailing icon sit quieter than the label',
        (tester) async {
      final hollow = await _pump(
        tester,
        HollowChip(
          label: 'RNNoise',
          hint: 'light, instant',
          trailingIcon: Icons.expand_more,
          onTap: () {},
        ),
      );

      final hint = tester.widget<Text>(find.text('light, instant'));
      expect(hint.style!.color, hollow.textTertiary);
      final trailing = tester.widget<Icon>(find.byIcon(Icons.expand_more));
      expect(trailing.color, hollow.textTertiary);
    });

    testWidgets('a leading widget takes the icon slot', (tester) async {
      await _pump(
        tester,
        HollowChip(
          label: 'Linux',
          icon: Icons.star,
          leading: const SizedBox(key: Key('glyph'), width: 14, height: 14),
          onTap: () {},
        ),
      );

      expect(find.byKey(const Key('glyph')), findsOneWidget);
      expect(find.byIcon(Icons.star), findsNothing);
    });
  });

  group('HollowKeyCombo', () {
    testWidgets('one mono badge per key', (tester) async {
      await _pump(tester, const HollowKeyCombo('Ctrl + Shift + M'));

      expect(find.byType(HollowBadge), findsNWidgets(3));
      for (final b in tester.widgetList<HollowBadge>(find.byType(HollowBadge))) {
        expect(b.kind, HollowBadgeKind.mono);
      }
      expect(find.text('+'), findsNWidgets(2));
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
      expect(iconTheme.color, hollow.textSecondary);
    });

    testWidgets('ghost is grey; outline uses accentText, never raw accent',
        (tester) async {
      // The accent means THE primary action, so ghost (everything else) is
      // grey. Outline stands beside a primary and keeps the accent, drawn in
      // the contrast-corrected accentText.
      var hollow = await _pump(tester,
          HollowButton.ghost(onPressed: () {}, child: const Text('Cancel')),
          light: true);
      var style =
          DefaultTextStyle.of(tester.element(find.text('Cancel'))).style;
      expect(style.color, hollow.textSecondary);

      hollow = await _pump(tester,
          HollowButton.outline(onPressed: () {}, child: const Text('Cancel')),
          light: true);
      style = DefaultTextStyle.of(tester.element(find.text('Cancel'))).style;
      expect(style.color, hollow.accentText);
      expect(style.color, isNot(hollow.accent));
    });

    testWidgets('danger labels its fill with the on-error token',
        (tester) async {
      final hollow = await _pump(tester,
          HollowButton.danger(onPressed: () {}, child: const Text('Delete')));
      final style =
          DefaultTextStyle.of(tester.element(find.text('Delete'))).style;
      expect(style.color, hollow.textOnError);
    });

    testWidgets('every variant is the same size, border included',
        (tester) async {
      for (final compact in [false, true]) {
        final sizes = <Size>{};
        for (final variant in HollowButtonVariant.values) {
          await _pump(
              tester,
              HollowButton(
                  variant: variant,
                  compact: compact,
                  onPressed: () {},
                  child: const Text('Save')));
          sizes.add(tester.getSize(find.byType(HollowButton)));
        }
        expect(sizes, hasLength(1), reason: 'compact: $compact');
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

    testWidgets('a tall action never pushes the subtitle off its title',
        (tester) async {
      await _pump(
        tester,
        const HollowSectionHeader(
          'Art you own',
          subtitle: 'or drop a pack here',
          action: SizedBox(width: 40, height: 80),
        ),
      );

      final titleBottom = tester.getBottomLeft(find.text('Art you own')).dy;
      final subtitleTop = tester.getTopLeft(find.text('or drop a pack here')).dy;
      expect(subtitleTop - titleBottom, lessThanOrEqualTo(HollowSpacing.xs));
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

    testWidgets('dense sits at the start of its card, one step smaller',
        (tester) async {
      await _pump(
        tester,
        const HollowEmptyState(title: 'No blocked users', dense: true),
      );

      expect(
        find.descendant(
          of: find.byType(HollowEmptyState),
          matching: find.byType(Center),
        ),
        findsNothing,
      );
      final text = tester.widget<Text>(find.text('No blocked users'));
      expect(text.style?.fontSize, HollowTypography.bodySmall.fontSize);
      expect(text.textAlign, TextAlign.start);
    });

    testWidgets('dense stays on the start edge inside a centring parent',
        (tester) async {
      // _pump already centres its child, as some mobile routes do.
      await _pump(
        tester,
        const SizedBox(
          key: Key('slot'),
          width: 400,
          child: HollowEmptyState(title: 'No blocked users', dense: true),
        ),
      );

      final box = tester.getTopLeft(find.byKey(const Key('slot')));
      expect(tester.getTopLeft(find.text('No blocked users')).dx, box.dx);
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
  group('HollowSpinner', () {
    testWidgets('three sizes on the icon ramp, quiet by default',
        (tester) async {
      final hollow = await _pump(tester, const HollowSpinner());

      expect(tester.getSize(find.byType(HollowSpinner)), const Size(14, 14));
      final ring = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator));
      // A spinner reports a state; the accent is kept for what can be acted on.
      expect(ring.color, hollow.textSecondary);

      await _pump(tester, const HollowSpinner.medium());
      expect(tester.getSize(find.byType(HollowSpinner)), const Size(20, 20));
      await _pump(tester, const HollowSpinner.large());
      expect(tester.getSize(find.byType(HollowSpinner)), const Size(32, 32));
    });

    testWidgets('announces itself as loading', (tester) async {
      await _pump(tester, const HollowSpinner());

      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    });
  });

  group('HollowButton loading', () {
    testWidgets('keeps its width, swaps the label for a spinner, ignores taps',
        (tester) async {
      var taps = 0;
      await _pump(
        tester,
        HollowButton.filled(onPressed: () => taps++, child: const Text('Save')),
      );
      final idle = tester.getSize(find.byType(HollowButton));

      await _pump(
        tester,
        HollowButton.filled(
          onPressed: () => taps++,
          loading: true,
          child: const Text('Save'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.getSize(find.byType(HollowButton)), idle);
      expect(find.byType(HollowSpinner), findsOneWidget);
      // The label's box must not stretch the ring into an oval.
      expect(tester.getSize(find.byType(CircularProgressIndicator)),
          const Size(14, 14));
      await tester.tap(find.byType(HollowButton), warnIfMissed: false);
      expect(taps, 0);
    });

    testWidgets('does not fade like a disabled button', (tester) async {
      await _pump(
        tester,
        const HollowButton.filled(
          onPressed: null,
          loading: true,
          child: Text('Save'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final fade = tester.widget<FadeTransition>(find.descendant(
        of: find.byType(HollowButton),
        matching: find.byType(FadeTransition),
      ).first);
      expect(fade.opacity.value, 1.0);
    });

    testWidgets('the spinner takes the variant foreground', (tester) async {
      final hollow = await _pump(
        tester,
        HollowButton.filled(
          onPressed: () {},
          loading: true,
          child: const Text('Save'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final spinner = tester.widget<HollowSpinner>(find.byType(HollowSpinner));
      expect(spinner.color, hollow.textOnAccent);
    });
  });

  group('HollowSlider', () {
    testWidgets('one geometry, the accent fill, no tick comb', (tester) async {
      final hollow = await _pump(
        tester,
        SizedBox(
          width: 240,
          child: HollowSlider(value: 0.5, divisions: 50, onChanged: (_) {}),
        ),
      );

      final theme = tester.widget<SliderTheme>(find.descendant(
        of: find.byType(HollowSlider),
        matching: find.byType(SliderTheme),
      )).data;
      expect(theme.trackHeight, HollowSlider.trackHeight);
      expect(theme.activeTrackColor, hollow.accent);
      expect(theme.inactiveTrackColor, hollow.border);
      expect(theme.tickMarkShape, SliderTickMarkShape.noTickMark);
    });

    testWidgets('clamps a value outside its range instead of asserting',
        (tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 240,
          child: HollowSlider(value: 3, max: 2, onChanged: (_) {}),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 2);
    });

    testWidgets('a finger gets 48 px of height, a pointer keeps it slim',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await _pump(
        tester,
        Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 240,
            child: HollowSlider(value: 0.5, onChanged: (_) {}),
          ),
        ]),
      );
      expect(tester.getSize(find.byType(Slider)).height,
          greaterThanOrEqualTo(HollowSlider.touchTarget));

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await _pump(
        tester,
        Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 240,
            child: HollowSlider(value: 0.5, onChanged: (_) {}),
          ),
        ]),
      );
      expect(tester.getSize(find.byType(Slider)).height,
          lessThan(HollowSlider.touchTarget));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('over media the unfilled track ignores the theme',
        (tester) async {
      final hollow = await _pump(
        tester,
        SizedBox(
          width: 240,
          child: HollowSlider(value: 0.5, onMedia: true, onChanged: (_) {}),
        ),
        light: true,
      );

      final theme = tester.widget<SliderTheme>(find.descendant(
        of: find.byType(HollowSlider),
        matching: find.byType(SliderTheme),
      )).data;
      expect(theme.inactiveTrackColor, isNot(hollow.border));
    });
  });

  group('HollowToggle', () {
    testWidgets('a finger gets 48 px while the switch stays 36 x 20',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var value = false;
      await _pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => HollowToggle(
            value: value,
            semanticLabel: 'Dark mode',
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      );

      expect(tester.getSize(find.byType(HollowToggle)), const Size(48, 48));
      // The corner of the hit area, outside the painted track.
      await tester.tapAt(tester.getTopLeft(find.byType(HollowToggle)) +
          const Offset(2, 2));
      await tester.pump();
      expect(value, isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('keeps its desktop size with a pointer', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await _pump(
        tester,
        HollowToggle(value: true, semanticLabel: 'Dark mode', onChanged: (_) {}),
      );

      expect(tester.getSize(find.byType(HollowToggle)), const Size(36, 20));
      expect(find.bySemanticsLabel('Dark mode'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('HollowDialog', () {
    BoxDecoration frameOf(WidgetTester tester) => tester
        .widget<DecoratedBox>(find
            .descendant(
                of: find.byType(HollowDialogSurface),
                matching: find.byType(DecoratedBox))
            .first)
        .decoration as BoxDecoration;

    testWidgets('frame is the overlay surface with a small shadow',
        (tester) async {
      final hollow = await _pump(
        tester,
        const HollowDialog(title: 'Title', content: Text('Body')),
      );
      final frame = frameOf(tester);
      expect(frame.color, hollow.overlay);
      expect(frame.boxShadow!.single.blurRadius, lessThanOrEqualTo(12));
      expect(frame.borderRadius, BorderRadius.circular(hollow.radiusLg));
    });

    testWidgets('a phone takes the sheet radius and the full width',
        (tester) async {
      tester.view.physicalSize = const Size(390, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final hollow = await _pump(
        tester,
        const HollowDialog(title: 'T', content: Text('Short')),
      );
      expect(frameOf(tester).borderRadius,
          BorderRadius.circular(hollow.radiusXl));
      final width = tester
          .getSize(find
              .descendant(
                  of: find.byType(HollowDialogSurface),
                  matching: find.byType(DecoratedBox))
              .first)
          .width;
      expect(width, 390 - HollowSpacing.xl * 2);
    });

    testWidgets('a fixed width holds on desktop', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        const HollowDialog(title: 'T', width: 420, content: Text('x')),
      );
      final size = tester.getSize(find
          .descendant(
              of: find.byType(HollowDialogSurface),
              matching: find.byType(DecoratedBox))
          .first);
      expect(size.width, 420);
    });

    testWidgets('showClose puts a labelled close button in the title row',
        (tester) async {
      await _pump(
        tester,
        const HollowDialog(
            title: 'Proof', showClose: true, content: Text('x')),
      );
      expect(find.byType(HollowDialogCloseButton), findsOneWidget);
      expect(find.bySemanticsLabel('Close'), findsOneWidget);
    });

    testWidgets('leading actions sit apart from the confirm',
        (tester) async {
      await _pump(
        tester,
        HollowDialog(
          title: 'T',
          content: const Text('x'),
          leadingActions: [
            HollowButton.ghost(onPressed: () {}, child: const Text('Reset')),
          ],
          actions: [
            HollowButton.filled(onPressed: () {}, child: const Text('Save')),
          ],
        ),
      );
      final reset = tester.getCenter(find.text('Reset'));
      final save = tester.getCenter(find.text('Save'));
      expect(reset.dy, save.dy);
      expect(save.dx - reset.dx, greaterThan(150));
    });

    testWidgets('showHollowConfirm resolves true only on the confirm',
        (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showHollowConfirm(
                    context: context,
                    title: 'Delete it?',
                    message: 'Gone for good.',
                    confirmLabel: 'Delete',
                    destructive: true,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final confirm = tester.widget<HollowButton>(find.ancestor(
          of: find.text('Delete'), matching: find.byType(HollowButton)));
      expect(confirm.variant, HollowButtonVariant.danger);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  });

  group('showHollowSheet', () {
    testWidgets('floats on the overlay surface with one handle',
        (tester) async {
      late HollowTheme hollow;
      await tester.pumpWidget(
        MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(builder: (context) {
              hollow = HollowTheme.of(context);
              return Center(
                child: TextButton(
                  onPressed: () => showHollowSheet<void>(
                    context: context,
                    builder: (_) => const Text('Sheet body'),
                  ),
                  child: const Text('Open'),
                ),
              );
            }),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      expect(find.text('Sheet body'), findsOneWidget);
      expect(find.byType(HollowSheetHandle), findsOneWidget);
      final surface = tester.widget<ColoredBox>(find
          .ancestor(of: find.byType(HollowSheetHandle), matching: find.byType(ColoredBox))
          .first);
      expect(surface.color, hollow.overlay);
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_duration_picker.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';

/// The dialogs-pass foundation: confirms and prompts that act inside the
/// dialog, phone touch sizing, friendlyError, the copy well, chip tabs,
/// labels as chips and badges, the duration picker, and the scroll opt-out.
late BuildContext _ctx;

Future<void> _pump(WidgetTester tester, {Widget? child, Size? size}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Builder(builder: (context) {
          _ctx = context;
          return Center(child: child ?? const SizedBox());
        }),
      ),
    ),
  );
}

HollowButton _button(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(HollowButton)));

crdt_api.LabelFfi _label({bool access = false}) => crdt_api.LabelFfi(
      labelId: 'l1',
      name: 'Artists',
      color: '#EC4899',
      access: access,
    );

void main() {
  group('showHollowConfirm', () {
    testWidgets('without onConfirm it answers at once, as before',
        (tester) async {
      await _pump(tester);
      late Future<bool> answer;
      answer = showHollowConfirm(
          context: _ctx, title: 'Leave?', message: 'Sure?', confirmLabel: 'Leave');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
      expect(find.text('Sure?'), findsNothing);
    });

    testWidgets('onConfirm keeps the dialog open and loading, then closes',
        (tester) async {
      await _pump(tester);
      final gate = Completer<void>();
      final answer = showHollowConfirm(
        context: _ctx,
        title: 'Kick member',
        message: 'They can rejoin with an invite.',
        confirmLabel: 'Kick',
        destructive: true,
        onConfirm: () => gate.future,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kick'));
      await tester.pump();

      expect(find.text('They can rejoin with an invite.'), findsOneWidget);
      expect(_button(tester, 'Kick').loading, isTrue);
      expect(_button(tester, 'Cancel').onPressed, isNull,
          reason: 'closing mid-flight would hide the outcome');

      gate.complete();
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
      expect(find.text('They can rejoin with an invite.'), findsNothing);
    });

    testWidgets('a failure stays inside the dialog and can be retried',
        (tester) async {
      await _pump(tester);
      var calls = 0;
      final answer = showHollowConfirm(
        context: _ctx,
        title: 'Delete server',
        message: 'This cannot be undone.',
        confirmLabel: 'Delete',
        destructive: true,
        onConfirm: () async {
          calls++;
          if (calls == 1) throw AnyhowException('relay not connected');
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining("can't reach the relay"), findsOneWidget);
      expect(find.textContaining('AnyhowException'), findsNothing);
      expect(_button(tester, 'Delete').loading, isFalse);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(await answer, isTrue);
    });

    testWidgets('Cancel after a failure answers false', (tester) async {
      await _pump(tester);
      final answer = showHollowConfirm(
        context: _ctx,
        title: 'Remove this?',
        message: 'It goes for everyone.',
        confirmLabel: 'Remove',
        onConfirm: () async => throw 'boom',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text(kGenericErrorSentence), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await answer, isFalse);
    });
  });

  group('promptForName', () {
    testWidgets('autofocuses, submits on Enter and resolves the trimmed name',
        (tester) async {
      await _pump(tester);
      final answer = promptForName(
          context: _ctx, title: 'New folder', confirmLabel: 'Create');
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
      await tester.enterText(find.byType(EditableText), '  Games  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(await answer, 'Games');
    });

    testWidgets('the confirm is disabled while the field is empty',
        (tester) async {
      await _pump(tester);
      promptForName(context: _ctx, title: 'Rename', confirmLabel: 'Rename');
      await tester.pumpAndSettle();
      expect(_button(tester, 'Rename').onPressed, isNull);
      await tester.enterText(find.byType(EditableText), 'x');
      await tester.pump();
      expect(_button(tester, 'Rename').onPressed, isNotNull);
    });

    testWidgets('a validator error sits on the field and keeps the text',
        (tester) async {
      await _pump(tester);
      promptForName(
        context: _ctx,
        title: 'Rename',
        confirmLabel: 'Rename',
        description: 'Only you see this name.',
        maxLength: 32,
        validator: (name) => name == 'taken' ? 'That name is taken.' : null,
      );
      await tester.pumpAndSettle();
      expect(find.text('Only you see this name.'), findsOneWidget);
      expect(find.text('0/32'), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'taken');
      await tester.pump();
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      expect(find.text('That name is taken.'), findsOneWidget);
      expect(find.text('taken'), findsOneWidget);
    });

    testWidgets('onSubmit runs inside the dialog; a throw lands on the field',
        (tester) async {
      await _pump(tester);
      final gate = Completer<void>();
      var fail = true;
      final answer = promptForName(
        context: _ctx,
        title: 'Rename channel',
        confirmLabel: 'Rename',
        initial: 'general',
        onSubmit: (_) async {
          if (fail) throw const FriendlyException('That name is taken.');
          await gate.future;
        },
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), 'lounge');
      await tester.pump();
      await tester.tap(find.text('Rename').last);
      await tester.pumpAndSettle();
      expect(find.text('That name is taken.'), findsOneWidget);
      expect(find.text('lounge'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Rename').last);
      await tester.pump();
      expect(_button(tester, 'Rename').loading, isTrue);
      gate.complete();
      await tester.pumpAndSettle();
      expect(await answer, 'lounge');
    });
  });

  group('phone touch sizing', () {
    testWidgets('a compact dialog grows its actions and close to 44',
        (tester) async {
      await _pump(tester, size: const Size(390, 800));
      showHollowDialog(
        context: _ctx,
        builder: (_) => HollowDialog(
          title: 'Leave server?',
          showClose: true,
          content: const HollowDialogText('You need a new invite.'),
          actions: [
            HollowButton.ghost(onPressed: () {}, child: const Text('Cancel')),
            HollowButton.danger(onPressed: () {}, child: const Text('Leave')),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final leave = find.ancestor(
          of: find.text('Leave'), matching: find.byType(AnimatedContainer));
      expect(tester.getSize(leave.first).height,
          greaterThanOrEqualTo(HollowButton.touchHeight));
      expect(tester.widget<HollowIconButton>(find.byType(HollowIconButton)).size,
          44);
    });

    testWidgets('a desktop dialog keeps its density', (tester) async {
      await _pump(tester, size: const Size(1280, 800));
      showHollowDialog(
        context: _ctx,
        builder: (_) => HollowDialog(
          title: 'Leave server?',
          showClose: true,
          content: const HollowDialogText('You need a new invite.'),
          actions: [
            HollowButton.danger(onPressed: () {}, child: const Text('Leave')),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final leave = find.ancestor(
          of: find.text('Leave'), matching: find.byType(AnimatedContainer));
      expect(tester.getSize(leave.first).height,
          lessThan(HollowButton.touchHeight));
      expect(tester.widget<HollowIconButton>(find.byType(HollowIconButton)).size,
          32);
    });
  });

  group('HollowDialog', () {
    testWidgets('scrollable: false leaves the content its own scroll view',
        (tester) async {
      await _pump(tester);
      showHollowDialog(
        context: _ctx,
        builder: (_) => HollowDialog(
          title: "What's new",
          scrollable: false,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(children: [
                    for (var i = 0; i < 80; i++) Text('Note $i'),
                  ]),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      await tester.drag(find.text('Note 3'), const Offset(0, -400));
      await tester.pumpAndSettle();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.pixels, greaterThan(0),
          reason: 'the inner view is the one that scrolls');
    });
  });

  group('friendlyError', () {
    test('maps the common shapes to one sentence with a next step', () {
      expect(friendlyError(AnyhowException('Relay not connected')),
          contains("can't reach the relay"));
      expect(friendlyError(TimeoutException('x')), contains('took too long'));
      expect(friendlyError('Permission denied: op_allowed'),
          contains("don't have permission"));
      expect(friendlyError(AnyhowException('server not found')),
          contains("couldn't find"));
      expect(friendlyError('label already exists'),
          contains('already exists'));
      expect(friendlyError(AnyhowException('Identity is locked')),
          contains('Unlock it'));
      expect(friendlyError('invalid hex in id'), contains('Check it'));
    });

    test('a sentence Rust wrote for people passes through', () {
      expect(friendlyError(AnyhowException('That pack has no stickers')),
          'That pack has no stickers.');
      expect(friendlyError(const FriendlyException('That name is taken.')),
          'That name is taken.');
    });

    test('debug text becomes the generic line, or the caller fallback', () {
      expect(friendlyError(AnyhowException('called `Option::unwrap()`')),
          kGenericErrorSentence);
      expect(friendlyError(StateError('bad state')), kGenericErrorSentence);
      expect(
          friendlyError(Exception('x'),
              fallback: "Couldn't leave the server. Try again."),
          "Couldn't leave the server. Try again.");
    });

    test('never an em dash, never a raw type name', () {
      for (final e in [
        'relay down', 'timed out', 'forbidden', 'not found', 'duplicate',
        'too large', 'invalid', 'no space left', 'rate limit', Object(),
      ]) {
        final text = friendlyError(e);
        expect(text.contains('—'), isFalse);
        expect(text.contains('Exception'), isFalse);
      }
    });
  });

  group('HollowCopyField', () {
    testWidgets('shows the value on elevated and copies with a toast',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      await _pump(tester,
          child: const SizedBox(
            width: 400,
            child: HollowCopyField(
                value: 'https://hollow.chat/#server=abc', name: 'invite link'),
          ));
      final hollow = HollowTheme.of(_ctx);
      final text = tester.widget<SelectableText>(find.byType(SelectableText));
      expect(text.style!.color, hollow.textPrimary);
      expect(text.style!.fontFamily, HollowTypography.mono.fontFamily);
      expect(find.bySemanticsLabel('Copy invite link'), findsOneWidget);

      await tester.tap(find.byType(HollowIconButton));
      await tester.pump();
      expect(copied, 'https://hollow.chat/#server=abc');
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('a label sits above and names the copy button',
        (tester) async {
      await _pump(tester,
          child: const SizedBox(
            width: 400,
            child: HollowCopyField(
                value: 'ABC123', label: 'Link code', wrap: false),
          ));
      expect(find.text('Link code'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy link code'), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing);
    });
  });

  group('HollowChipTabs', () {
    Widget tabs(ValueNotifier<int> picked, {bool expand = false}) =>
        ValueListenableBuilder<int>(
          valueListenable: picked,
          builder: (_, value, _) => SizedBox(
            width: 360,
            child: HollowChipTabs<int>(
              selected: value,
              expand: expand,
              onSelected: (v) => picked.value = v,
              tabs: const [
                HollowChipTab(value: 0, label: 'Friends', hint: '12'),
                HollowChipTab(value: 1, label: 'Requests', count: 3),
                HollowChipTab(value: 2, label: 'Add friend'),
              ],
            ),
          ),
        );

    testWidgets('a row of HollowChips, one selected, counts as a badge',
        (tester) async {
      final picked = ValueNotifier(0);
      await _pump(tester, child: tabs(picked));
      expect(find.byType(HollowChip), findsNWidgets(3));
      expect(
          tester.widgetList<HollowChip>(find.byType(HollowChip))
              .where((c) => c.selected)
              .map((c) => c.label),
          ['Friends']);
      expect(find.text('12'), findsOneWidget);
      expect(find.byType(HollowCountBadge), findsOneWidget);
      await tester.tap(find.text('Add friend'));
      await tester.pump();
      expect(picked.value, 2);
    });

    testWidgets('arrow keys move the selection and wrap', (tester) async {
      final picked = ValueNotifier(0);
      await _pump(tester, child: tabs(picked));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(picked.value, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(picked.value, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(picked.value, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(picked.value, 2);
    });

    testWidgets('expand gives equal widths', (tester) async {
      await _pump(tester, child: tabs(ValueNotifier(0), expand: true));
      final widths = tester
          .widgetList(find.byType(HollowChip))
          .map((w) => tester.getSize(find.byWidget(w)).width)
          .toSet();
      expect(widths.length, 1);
    });
  });

  group('labels', () {
    testWidgets('LabelChip is a HollowChip led by its colour', (tester) async {
      await _pump(tester,
          child: LabelChip(label: _label(access: true), selected: true,
              onTap: () {}));
      final chip = tester.widget<HollowChip>(find.byType(HollowChip));
      expect(chip.selected, isTrue);
      expect(chip.leading, isA<LabelSwatch>());
      final text = tester.widget<Text>(find.text('Artists'));
      expect(text.style!.fontWeight, HollowTypography.label.fontWeight,
          reason: 'selection never changes the weight');
    });

    testWidgets('LabelTypeChip is a HollowChip with its icon', (tester) async {
      await _pump(tester,
          child: LabelTypeChip(
              icon: Icons.lock, text: 'Access', selected: false, onTap: () {}));
      expect(tester.widget<HollowChip>(find.byType(HollowChip)).icon,
          Icons.lock);
    });

    testWidgets('LabelBadge is a HollowBadge, never tappable', (tester) async {
      await _pump(tester, child: LabelBadge(label: _label()));
      expect(find.byType(HollowBadge), findsOneWidget);
      expect(find.byType(HollowChip), findsNothing);
    });
  });

  group('HollowDurationPicker', () {
    test('labels say the length plainly', () {
      expect(hollowDurationLabel(const Duration(minutes: 10)), '10 minutes');
      expect(hollowDurationLabel(const Duration(hours: 1)), '1 hour');
      expect(hollowDurationLabel(const Duration(hours: 24)), '24 hours');
      expect(hollowDurationLabel(const Duration(days: 7)), '7 days');
      expect(hollowDurationLabel(null), 'until I remove it');
    });

    testWidgets('a chip row; "Until I remove it" is a plain choice',
        (tester) async {
      Duration? picked = const Duration(hours: 1);
      await _pump(tester,
          child: StatefulBuilder(
            builder: (context, setState) => SizedBox(
              width: 420,
              child: HollowDurationPicker(
                value: picked,
                onChanged: (d) => setState(() => picked = d),
              ),
            ),
          ));
      expect(find.byType(HollowChip),
          findsNWidgets(kHollowDurationPresets.length));
      expect(find.byType(HollowButton), findsNothing);
      await tester.tap(find.text('Until I remove it'));
      await tester.pump();
      expect(picked, isNull);
      final hollow = HollowTheme.of(_ctx);
      expect(tester.widget<Text>(find.text('Until I remove it')).style!.color,
          isNot(hollow.error));
    });

    testWidgets('the dialog acts on ONE filled confirm with the choice',
        (tester) async {
      await _pump(tester);
      Duration? sent = Duration.zero;
      final done = showHollowDurationDialog(
        context: _ctx,
        title: 'Mute member',
        message: 'For how long?',
        confirmLabel: 'Mute',
        onConfirm: (d) async => sent = d,
      );
      await tester.pumpAndSettle();
      expect(
          tester
              .widgetList<HollowButton>(find.byType(HollowButton))
              .where((b) => b.variant == HollowButtonVariant.filled)
              .length,
          1);
      await tester.tap(find.text('7 days'));
      await tester.pump();
      await tester.tap(find.text('Mute'));
      await tester.pumpAndSettle();
      expect(await done, isTrue);
      expect(sent, const Duration(days: 7));
    });
  });
}

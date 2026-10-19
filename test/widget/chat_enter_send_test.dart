import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';

import '../helpers/test_app.dart';

/// Both Enter keys, the main one and the numpad's, send, and with Shift they
/// break the line. An Enter the framework leaves unhandled reaches the text
/// input client, which inserts a newline into a multiline field: the numpad
/// key used to do exactly that.
const _enterKeys = {
  'Enter': LogicalKeyboardKey.enter,
  'numpad Enter': LogicalKeyboardKey.numpadEnter,
};

/// Windows reports the numpad key as Enter itself, and the key simulator has
/// no Windows code for the numpad one.
TargetPlatformVariant _platformsFor(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.numpadEnter
        ? TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.linux})
        : TargetPlatformVariant.desktop();

void main() {
  test('every Enter check in lib also takes the numpad key', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      if (src.contains('LogicalKeyboardKey.enter') &&
          !src.contains('LogicalKeyboardKey.numpadEnter')) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'match Enter through isEnterKey (chat_input_shortcuts.dart)');
  });

  group('composer', () {
    late EmoteComposerController controller;
    late FocusNode focus;
    late List<String> sent;
    late List<bool> handled;

    Future<void> pump(WidgetTester tester) async {
      controller = EmoteComposerController();
      focus = FocusNode();
      sent = [];
      handled = [];
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      void send() {
        final text = controller.expandedText().trim();
        if (text.isEmpty) return;
        controller.clear();
        focus.requestFocus();
        sent.add(text);
      }

      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatComposerRow(
                controller: controller,
                focusNode: focus,
                hintText: 'Message b',
                onChanged: (_) {},
                onKey: (event) =>
                    handleChatInputKey(event, controller, focus, send),
                layerLink: LayerLink(),
                onExpressions: (_) {},
                onSend: send,
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byType(EditableText));
      await tester.pump();
    }

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key,
        {bool shift = false}) async {
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      handled.add(await tester.sendKeyDownEvent(key));
      await tester.sendKeyUpEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
    }

    for (final MapEntry(key: label, value: key) in _enterKeys.entries) {
      testWidgets('$label sends every time', (tester) async {
        await pump(tester);
        for (final msg in ['Hello there', 'Second one', 'Third']) {
          await tester.enterText(find.byType(EditableText), msg);
          await press(tester, key);
        }
        expect(sent, ['Hello there', 'Second one', 'Third']);
        expect(handled, [true, true, true]);
        expect(controller.text, isEmpty);
      }, variant: _platformsFor(key));

      testWidgets('Shift+$label breaks the line', (tester) async {
        await pump(tester);
        await tester.enterText(find.byType(EditableText), 'Two');
        await press(tester, key, shift: true);
        expect(controller.text, 'Two\n');
        expect(sent, isEmpty);
        expect(handled, [true]);
      }, variant: _platformsFor(key));
    }
  });

  group('edit field', () {
    late List<String> submitted;
    late int cancelled;

    Future<void> pump(WidgetTester tester) async {
      submitted = [];
      cancelled = 0;
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: MessageActionBarScope(
              child: MessageHoverWrapper(
                isMe: true,
                messageId: 'm-1',
                currentText: 'old words',
                isEditing: true,
                onEditSubmit: submitted.add,
                onEditCancel: () => cancelled++,
                child: const Text('old words'),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    for (final MapEntry(key: label, value: key) in _enterKeys.entries) {
      testWidgets('$label saves the edit', (tester) async {
        await pump(tester);
        await tester.enterText(find.byType(EditableText), 'new words');
        expect(await tester.sendKeyEvent(key), isTrue);
        expect(submitted, ['new words']);
        expect(cancelled, 0);
      }, variant: _platformsFor(key));

      testWidgets('Shift+$label breaks the line in the edit', (tester) async {
        await pump(tester);
        await tester.enterText(find.byType(EditableText), 'new');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        expect(await tester.sendKeyEvent(key), isTrue);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        final field = tester.widget<EditableText>(find.byType(EditableText));
        expect(field.controller.text, 'new\n');
        expect(submitted, isEmpty);
      }, variant: _platformsFor(key));
    }
  });

  group('emote suggestions', () {
    for (final MapEntry(key: label, value: key) in _enterKeys.entries) {
      testWidgets('$label picks the highlighted emoji', (tester) async {
        final controller = EmoteComposerController();
        addTearDown(controller.dispose);
        final link = LayerLink();
        final autocomplete = EmoteAutocomplete(
            link: link, controller: controller, emotesSource: () => const []);
        addTearDown(autocomplete.dismiss);
        late BuildContext ctx;
        await tester.pumpWidget(MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: CompositedTransformTarget(
              link: link,
              child: Builder(builder: (c) {
                ctx = c;
                return const SizedBox(width: 200, height: 40);
              }),
            ),
          ),
        ));
        controller.value = const TextEditingValue(
            text: ':fire', selection: TextSelection.collapsed(offset: 5));
        autocomplete.update(ctx, controller.text);
        await tester.pump();
        expect(autocomplete.isActive, isTrue);

        final r = autocomplete.handleKey(KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.numpadEnter,
          logicalKey: key,
          timeStamp: Duration.zero,
        ));
        expect(r, KeyEventResult.handled);
        expect(controller.text, isNot(':fire'));
        expect(controller.text, isNot(contains('\n')));
        expect(autocomplete.isActive, isFalse);
      });
    }
  });
}

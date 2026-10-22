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

/// The macOS and Linux engines show a key to the framework before the input
/// method, so the Enter that confirms a Japanese conversion reached the
/// composer and sent the half-composed text. There a field that holds marked
/// text leaves Enter, Escape and the arrows to the IME. Windows never shows
/// the IME's keys (VK_PROCESSKEY) and phones keep a composing range over the
/// word being typed, so there Enter still sends.

/// Kana typed, not yet converted: the IME marks all of it.
const _composing = TextEditingValue(
  text: 'にほんご',
  selection: TextSelection.collapsed(offset: 4),
  composing: TextRange(start: 0, end: 4),
);

/// The same after the Enter that confirms the conversion.
const _committed = TextEditingValue(
  text: '日本語',
  selection: TextSelection.collapsed(offset: 3),
);

final _desktop = TargetPlatformVariant.desktop();

/// Where the engine shows a key to the framework before the IME.
const _imeLate =
    TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.linux});
const _phones =
    TargetPlatformVariant({TargetPlatform.iOS, TargetPlatform.android});
const _sendsOverComposing = TargetPlatformVariant(
    {TargetPlatform.windows, TargetPlatform.iOS, TargetPlatform.android});

/// Windows reports the numpad key as Enter itself, and the key simulator has
/// no Windows code for the numpad one.
const _numpadDesktops =
    TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.linux});

void main() {
  test('every key handler in lib/src/ui asks the IME first', () {
    // Files whose handlers sit on no text field, with the reason.
    const noTextField = {
      'annotation/annotation_overlay.dart': 'drawing canvas',
      'components/hollow_chip_tabs.dart': 'its own focus node, a tab row',
      'components/hollow_focus_ring.dart': 'buttons and pressables',
      'components/hollow_tab_bar.dart': 'its own focus node, a tab row',
      'components/ime_keys.dart': 'the rule itself',
      'components/panel_resize_handle.dart': 'its own focus node',
      'components/server_folder_popup.dart': 'a folder of server icons',
      'dialogs/image_crop_dialog.dart': 'an image, no field',
      'media/media_viewer_route.dart': 'the media viewer, no field',
      'settings/keybind_capture_field.dart': 'captures raw keys, no IME',
    };
    final keyTest = RegExp(r'LogicalKeyboardKey\.(escape|enter|numpadEnter|'
        r'arrowUp|arrowDown|arrowLeft|arrowRight|tab)\b|isEnterKey\(');
    final handlerStart = RegExp(r'onKeyEvent:|KeyEventResult\??\s+\w+\(|'
        r'bool\s+_onKey\(');
    final offenders = <String>[];
    for (final f in Directory('lib/src/ui').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final rel = f.path.replaceAll(r'\', '/').split('lib/src/ui/').last;
      if (noTextField.containsKey(rel)) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!keyTest.hasMatch(lines[i])) continue;
        var start = i;
        while (start > 0 && !handlerStart.hasMatch(lines[start])) {
          start--;
        }
        // The check may close the same condition, a line or two below.
        final end = (i + 3).clamp(0, lines.length);
        final body = lines.sublist(start, end).join('\n');
        if (!body.contains('keyBelongsTo')) offenders.add('$rel:${i + 1}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'a handler that takes Enter, Escape, an arrow or Tab over a '
            'text field asks keyBelongsToIme / keyBelongsToFocusedIme '
            '(components/ime_keys.dart) before it, or names its file in '
            'noTextField with the reason');
  });

  group('composer', () {
    late EmoteComposerController controller;
    late FocusNode focus;
    late List<String> sent;

    Future<void> pump(WidgetTester tester) async {
      controller = EmoteComposerController();
      focus = FocusNode();
      sent = [];
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
                enterSends: true,
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
    }

    Future<void> ime(WidgetTester tester, TextEditingValue value) async {
      tester.testTextInput.updateEditingValue(value);
      await tester.pump();
    }

    Future<bool> press(WidgetTester tester, LogicalKeyboardKey key,
        {LogicalKeyboardKey? modifier}) async {
      if (modifier != null) await tester.sendKeyDownEvent(modifier);
      final handled = await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      if (modifier != null) await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      return handled;
    }

    testWidgets('Enter that confirms a conversion goes to the IME',
        (tester) async {
      await pump(tester);
      await ime(tester, _composing);
      expect(await press(tester, LogicalKeyboardKey.enter), isFalse);
      expect(sent, isEmpty);
      expect(controller.text, 'にほんご');

      await ime(tester, _committed);
      expect(await press(tester, LogicalKeyboardKey.enter), isTrue);
      expect(sent, ['日本語']);
      expect(controller.text, isEmpty);
    }, variant: _imeLate);

    testWidgets('Live Conversion: Enter over converted marked text confirms',
        (tester) async {
      await pump(tester);
      // macOS Japanese with Live Conversion (on by default): typing nihongo
      // shows 日本語 already converted, still marked, the clause selected and
      // the candidate list open. No Space step comes first.
      await ime(
          tester,
          const TextEditingValue(
            text: '日本語',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
            composing: TextRange(start: 0, end: 3),
          ));
      // Linux's own text shortcuts take the arrows; only ours must not.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(await press(tester, LogicalKeyboardKey.enter), isFalse);
      expect(sent, isEmpty);
      expect(controller.text, '日本語');

      await ime(tester, _committed);
      expect(await press(tester, LogicalKeyboardKey.enter), isTrue);
      expect(sent, ['日本語']);
    }, variant: _imeLate);

    testWidgets('an emptied composition no longer holds Enter',
        (tester) async {
      await pump(tester);
      // macOS clears marked text with an empty composition, not none.
      await ime(
          tester,
          const TextEditingValue(
            text: 'done',
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange.collapsed(4),
          ));
      expect(await press(tester, LogicalKeyboardKey.enter), isTrue);
      expect(sent, ['done']);
    }, variant: _desktop);

    testWidgets('numpad Enter goes to the IME too, then sends',
        (tester) async {
      await pump(tester);
      await ime(tester, _composing);
      expect(await press(tester, LogicalKeyboardKey.numpadEnter), isFalse);
      expect(sent, isEmpty);
      await ime(tester, _committed);
      expect(await press(tester, LogicalKeyboardKey.numpadEnter), isTrue);
      expect(sent, ['日本語']);
    }, variant: _numpadDesktops);

    testWidgets('Shift+Enter while composing adds no line', (tester) async {
      await pump(tester);
      await ime(tester, _composing);
      expect(
          await press(tester, LogicalKeyboardKey.enter,
              modifier: LogicalKeyboardKey.shiftLeft),
          isFalse);
      expect(controller.text, 'にほんご');
      expect(sent, isEmpty);
    }, variant: _imeLate);

    testWidgets('Windows and phones send over a composing range',
        (tester) async {
      await pump(tester);
      await ime(
          tester,
          const TextEditingValue(
            text: 'see you',
            selection: TextSelection.collapsed(offset: 7),
            composing: TextRange(start: 4, end: 7),
          ));
      expect(await press(tester, LogicalKeyboardKey.enter), isTrue);
      expect(sent, ['see you']);
    }, variant: _sendsOverComposing);

    testWidgets('Ctrl+Enter breaks the line', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(EditableText), 'Two');
      expect(
          await press(tester, LogicalKeyboardKey.enter,
              modifier: LogicalKeyboardKey.controlLeft),
          isTrue);
      expect(controller.text, 'Two\n');
      expect(sent, isEmpty);
    }, variant: _imeLate);

    testWidgets('a macOS or Linux composer declares send as its Enter action',
        (tester) async {
      await pump(tester);
      expect(tester.testTextInput.setClientArgs!['inputAction'],
          TextInputAction.send.toString());
    }, variant: _imeLate);

    testWidgets('Windows and phone composers keep their newline key',
        (tester) async {
      await pump(tester);
      expect(tester.testTextInput.setClientArgs!['inputAction'],
          TextInputAction.newline.toString());
    }, variant: _sendsOverComposing);

    testWidgets('an Enter the IME hands back sends and keeps focus',
        (tester) async {
      await pump(tester);
      await ime(
          tester,
          const TextEditingValue(
            text: '안녕',
            selection: TextSelection.collapsed(offset: 2),
          ));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(sent, ['안녕']);
      expect(focus.hasFocus, isTrue);
    }, variant: _imeLate);

    testWidgets('a handed-back Shift+Enter breaks the line', (tester) async {
      await pump(tester);
      await ime(
          tester,
          const TextEditingValue(
            text: '안녕',
            selection: TextSelection.collapsed(offset: 2),
          ));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(sent, isEmpty);
      expect(controller.text, '안녕\n');
    }, variant: _imeLate);

    testWidgets('a hand-back over a range the engine kept loses no text',
        (tester) async {
      await pump(tester);
      // macOS insertNewline: commits marked text in the engine's own model
      // and sends no update before the action.
      await ime(
          tester,
          const TextEditingValue(
            text: 'meet at hello',
            selection: TextSelection.collapsed(offset: 13),
            composing: TextRange(start: 8, end: 13),
          ));
      expect(await press(tester, LogicalKeyboardKey.enter), isFalse);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(sent, isEmpty);
      expect(controller.text, 'meet at hello');
      expect(controller.value.composing.isValid, isFalse);

      expect(await press(tester, LogicalKeyboardKey.enter), isTrue);
      expect(sent, ['meet at hello']);
    }, variant: _imeLate);

    testWidgets('a composer whose Enter does not send keeps its newline key',
        (tester) async {
      final c = EmoteComposerController();
      final f = FocusNode();
      addTearDown(c.dispose);
      addTearDown(f.dispose);
      // The mobile shell's composer, which a narrow desktop window shows too.
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatComposerRow(
                controller: c,
                focusNode: f,
                hintText: 'Message b',
                onChanged: (_) {},
                onKey: (_) => KeyEventResult.ignored,
                layerLink: LayerLink(),
                onExpressions: (_) {},
                onSend: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
      expect(tester.testTextInput.setClientArgs!['inputAction'],
          TextInputAction.newline.toString());
    }, variant: _desktop);
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
      await tester.showKeyboard(find.byType(EditableText));
      await tester.pump();
    }

    testWidgets('Enter and Escape go to the IME, then Enter saves',
        (tester) async {
      await pump(tester);
      tester.testTextInput.updateEditingValue(_composing);
      await tester.pump();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isFalse);
      // Linux and Windows have no text shortcut for Escape, so a framework
      // action further up may take it; the edit itself must stay open.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(submitted, isEmpty);
      expect(cancelled, 0);

      tester.testTextInput.updateEditingValue(_committed);
      await tester.pump();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
      expect(submitted, ['日本語']);
    }, variant: _imeLate);

    testWidgets('an Enter the IME hands back saves', (tester) async {
      await pump(tester);
      expect(tester.testTextInput.setClientArgs!['inputAction'],
          TextInputAction.send.toString());
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '안녕',
        selection: TextSelection.collapsed(offset: 2),
      ));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(submitted, ['안녕']);
    }, variant: _imeLate);

    testWidgets('a phone edit keeps saving over the word being typed',
        (tester) async {
      await pump(tester);
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: 'new words',
        selection: TextSelection.collapsed(offset: 9),
        composing: TextRange(start: 4, end: 9),
      ));
      await tester.pump();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
      expect(submitted, ['new words']);
    }, variant: _phones);
  });

  group('emote suggestions', () {
    testWidgets('Enter and the arrows go to the IME while composing',
        (tester) async {
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
        text: ':fire',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 1, end: 5),
      );
      autocomplete.update(ctx, controller.text);
      await tester.pump();
      expect(autocomplete.isActive, isTrue);

      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.tab,
      ]) {
        final r = autocomplete.handleKey(KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.enter,
          logicalKey: key,
          timeStamp: Duration.zero,
        ));
        expect(r, KeyEventResult.ignored, reason: '$key');
      }
      expect(controller.text, ':fire');
      expect(autocomplete.isActive, isTrue);
    }, variant: _imeLate);
  });
}

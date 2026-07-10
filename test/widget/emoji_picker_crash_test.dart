// Repro harness for the 2026-07-10 crash.log overlay crash:
// "Null check operator used on a null value" in _OverlayEntryWidgetState
// .initState after interacting with the emoji picker's search bar.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';

Widget _host({required void Function(BuildContext) onOpen}) {
  return ProviderScope(
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => onOpen(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('picker: open → type in search → select emoji → reopen',
      (tester) async {
    final selections = <String>[];
    await tester.pumpWidget(_host(onOpen: (context) {
      showEmojiPicker(
        context: context,
        anchorPosition: const Offset(400, 500),
        onSelect: selections.add,
      );
    }));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPickerBody), findsOneWidget);

    // Type in the search bar (this is what the crash report fingered).
    await tester.enterText(find.byType(TextField).first, 'fire');
    await tester.pumpAndSettle();

    // Select the first filtered emoji.
    final cell = find.text('🔥');
    expect(cell, findsWidgets);
    await tester.tap(cell.first);
    await tester.pumpAndSettle();
    expect(selections, isNotEmpty);
    expect(find.byType(EmojiPickerBody), findsNothing);

    // Reopen and dismiss via the barrier.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPickerBody), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(EmojiPickerBody), findsNothing);
  });

  testWidgets('picker: rapid double-tap on an emoji cell', (tester) async {
    final selections = <String>[];
    await tester.pumpWidget(_host(onOpen: (context) {
      showEmojiPicker(
        context: context,
        anchorPosition: const Offset(400, 500),
        onSelect: selections.add,
      );
    }));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final cell = find.text('😀');
    expect(cell, findsWidgets);
    // Two taps with NO pump between them — both land before the overlay
    // removal is built out.
    await tester.tap(cell.first);
    await tester.tap(cell.first, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(selections, isNotEmpty);
  });

  // Component-level guard for the root cause: HollowTextField used to build
  // a NEW MaterialTextSelectionControls() every rebuild; the identity change
  // per keystroke (its state setState's on every text change) made
  // EditableText recreate its selection-overlay entries, which crashed the
  // whole app when the field lived inside a raw OverlayEntry.
  testWidgets('HollowTextField inside a raw OverlayEntry survives typing',
      (tester) async {
    await tester.pumpWidget(_host(onOpen: (context) {
      final entry = OverlayEntry(
        builder: (ctx) => const Positioned(
          left: 50,
          top: 50,
          width: 200,
          child: Material(
            color: Colors.transparent,
            child: HollowTextField(hintText: 'search', autofocus: true),
          ),
        ),
      );
      Overlay.of(context).insert(entry);
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'several');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'keystrokes');
    await tester.pumpAndSettle();
  });

  testWidgets('picker: search while empty tabs + tab switching', (tester) async {
    await tester.pumpWidget(_host(onOpen: (context) {
      showEmojiPicker(
        context: context,
        anchorPosition: const Offset(400, 500),
        serverId: 'srv-1',
        onSelect: (_) {},
      );
    }));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mine'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emoji'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });
}

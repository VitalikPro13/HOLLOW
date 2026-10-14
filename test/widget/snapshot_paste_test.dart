import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/win32_clipboard.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/components/snapshot_paste.dart';

/// Issue #101: a dictation app (Handy) puts its transcript on the clipboard,
/// presses Ctrl+V and puts the old clipboard back about 160 ms later. The
/// engine's own paste opens the clipboard once, after a thread hop, and gives
/// up when anyone holds it at that instant, so the transcript never landed.
/// Paste now reads the clipboard during the key event.
void main() {
  late List<String> engineReads;
  ClipboardSnapshot? Function(int attempts)? savedReader;

  setUp(() {
    engineReads = [];
    savedReader = pasteSnapshotReader;
  });

  tearDown(() {
    pasteSnapshotReader = savedReader;
  });

  /// The engine's read fails the way it does while another process holds
  /// the clipboard (`platform_handler.cc`: "Unable to open clipboard").
  void engineClipboardBusy(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          engineReads.add('getData');
          throw PlatformException(
              code: 'Clipboard error', message: 'Unable to open clipboard');
        }
        return null;
      },
    );
  }

  void engineClipboardHolds(WidgetTester tester, String text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          engineReads.add('getData');
          return <String, dynamic>{'text': text};
        }
        return null;
      },
    );
  }

  Future<void> pressCtrlV(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  group('app-wide paste action', () {
    Future<TextEditingController> pumpField(WidgetTester tester,
        {int? maxLength, String initial = ''}) async {
      final controller = TextEditingController(text: initial);
      await tester.pumpWidget(MaterialApp(
        actions: hollowAppActions(),
        home: Scaffold(
          body: TextField(
            controller: controller,
            autofocus: true,
            maxLength: maxLength,
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    testWidgets('Ctrl+V pastes the key-time snapshot while the engine read fails',
        (tester) async {
      engineClipboardBusy(tester);
      pasteSnapshotReader = (_) => const ClipboardSnapshot(text: 'dictated words');
      final controller = await pumpField(tester);

      await pressCtrlV(tester);

      expect(controller.text, 'dictated words');
      expect(controller.selection, const TextSelection.collapsed(offset: 14));
      expect(engineReads, isEmpty,
          reason: 'one read per paste, taken during the key event');
    });

    testWidgets('a selection is replaced and the caret lands after the paste',
        (tester) async {
      engineClipboardBusy(tester);
      pasteSnapshotReader = (_) => const ClipboardSnapshot(text: 'fine');
      final controller = await pumpField(tester, initial: 'say ok here');
      controller.selection = const TextSelection(baseOffset: 4, extentOffset: 6);
      await tester.pump();

      await pressCtrlV(tester);

      expect(controller.text, 'say fine here');
      expect(controller.selection, const TextSelection.collapsed(offset: 8));
    });

    testWidgets('Shift+Insert pastes the snapshot too', (tester) async {
      engineClipboardBusy(tester);
      pasteSnapshotReader = (_) => const ClipboardSnapshot(text: 'typed by voice');
      final controller = await pumpField(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.insert);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(controller.text, 'typed by voice');
    });

    testWidgets('the field length limit still applies', (tester) async {
      engineClipboardBusy(tester);
      pasteSnapshotReader = (_) => const ClipboardSnapshot(text: 'dictated words');
      final controller = await pumpField(tester, maxLength: 5);

      await pressCtrlV(tester);

      expect(controller.text, 'dicta');
    });

    testWidgets('without a synchronous read the engine paste runs',
        (tester) async {
      engineClipboardHolds(tester, 'from the engine');
      pasteSnapshotReader = null;
      final controller = await pumpField(tester);

      await pressCtrlV(tester);
      await tester.pumpAndSettle();

      expect(engineReads, ['getData']);
      expect(controller.text, 'from the engine');
    });

    testWidgets('a clipboard held past the key event pastes once it is free',
        (tester) async {
      engineClipboardBusy(tester);
      var reads = 0;
      pasteSnapshotReader = (_) =>
          ++reads < 6 ? null : const ClipboardSnapshot(text: 'dictated words');
      final controller = await pumpField(tester);

      await pressCtrlV(tester);
      expect(controller.text, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.text, 'dictated words');
      expect(engineReads, isEmpty);
    });

    testWidgets('a clipboard held throughout pastes nothing and stops trying',
        (tester) async {
      engineClipboardBusy(tester);
      var reads = 0;
      pasteSnapshotReader = (_) {
        reads++;
        return null;
      };
      final controller = await pumpField(tester);

      await pressCtrlV(tester);
      await tester.pump(const Duration(seconds: 2));
      final settled = reads;
      await tester.pump(const Duration(seconds: 2));

      expect(controller.text, isEmpty);
      expect(reads, settled, reason: 'no reads after the window closes');
      expect(engineReads, isEmpty);
    });
  });

  group('Win32 clipboard read', () {
    test('waits out a holder that releases within the retry window', () async {
      final held = await _holdClipboard(const Duration(milliseconds: 30));
      final snapshot = readWin32ClipboardSnapshot(10);
      await held.done;
      expect(held.opened, isTrue, reason: 'the helper process held the clipboard');
      expect(snapshot, isNotNull);
    }, skip: !Platform.isWindows);

    test('gives up within the cap while a holder keeps it', () async {
      final held = await _holdClipboard(const Duration(milliseconds: 400));
      final watch = Stopwatch()..start();
      final snapshot = readWin32ClipboardSnapshot(10);
      watch.stop();
      await held.done;
      expect(held.opened, isTrue);
      expect(snapshot, isNull);
      expect(watch.elapsedMilliseconds, lessThan(200));
    }, skip: !Platform.isWindows);
  });

  group('chat composer Ctrl+V', () {
    Future<TextEditingController> pumpComposer(
      WidgetTester tester, {
      void Function(String path, String name)? onPasteImage,
    }) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(MaterialApp(
        actions: hollowAppActions(),
        home: Scaffold(
          body: Focus(
            onKeyEvent: (_, event) => handleChatInputKey(
              event,
              controller,
              focusNode,
              () {},
              onPasteImage: onPasteImage,
            ),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
            ),
          ),
        ),
      ));
      await tester.pump();
      return controller;
    }

    testWidgets('text-only clipboard: the text lands and no image read starts',
        (tester) async {
      engineClipboardBusy(tester);
      var reads = 0;
      pasteSnapshotReader = (_) {
        reads++;
        return const ClipboardSnapshot(text: 'dictated words');
      };
      final images = <String>[];
      final controller =
          await pumpComposer(tester, onPasteImage: (p, n) => images.add(n));

      await pressCtrlV(tester);

      expect(controller.text, 'dictated words');
      expect(reads, 1, reason: 'the composer and the app action share one read');
      expect(images, isEmpty);
      expect(engineReads, isEmpty);
    });

    testWidgets('an empty clipboard pastes nothing and asks nobody else',
        (tester) async {
      engineClipboardBusy(tester);
      pasteSnapshotReader = (_) => const ClipboardSnapshot();
      final controller = await pumpComposer(tester);

      await pressCtrlV(tester);

      expect(controller.text, isEmpty);
      expect(engineReads, isEmpty);
    });
  });
}

class _Held {
  final bool opened;
  final Future<void> done;
  _Held(this.opened, this.done);
}

/// Opens the clipboard in another process, with an owner window, and keeps it
/// for [hold], the way clipboard history or a clipboard manager does. Two
/// ownerless opens never block each other, so the owner window matters.
Future<_Held> _holdClipboard(Duration hold) async {
  final script = r'''
Add-Type -Name C -Namespace W -MemberDefinition '[DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h); [DllImport("user32.dll")] public static extern bool CloseClipboard();'
Add-Type -AssemblyName System.Windows.Forms
$owner = (New-Object System.Windows.Forms.Form).Handle
$ok = $false
for ($i = 0; $i -lt 100 -and -not $ok; $i++) { $ok = [W.C]::OpenClipboard($owner); if (-not $ok) { Start-Sleep -Milliseconds 2 } }
[Console]::Out.WriteLine("opened=$ok"); [Console]::Out.Flush()
Start-Sleep -Milliseconds HOLD_MS
if ($ok) { [void][W.C]::CloseClipboard() }
'''.replaceAll('HOLD_MS', '${hold.inMilliseconds}');
  final encoded = base64.encode(
      script.codeUnits.expand((c) => [c & 0xff, c >> 8]).toList());
  final process = await Process.start(
      'powershell', ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded]);
  final lines =
      process.stdout.transform(utf8.decoder).transform(const LineSplitter());
  final first = await lines.firstWhere((l) => l.startsWith('opened='));
  return _Held(first.trim() == 'opened=True', process.exitCode);
}

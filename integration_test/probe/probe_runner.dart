import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'probe_dump.dart';
import 'probe_targets.dart';

/// Executes probe steps. A step is a JSON object, so the same runner serves a
/// scenario file, an inline scenario, and the live command loop, and adding a
/// scenario never means rebuilding the app.
///
/// ## The ops
///
/// | op | args | does |
/// |---|---|---|
/// | `open_server` | `name` | clicks a server icon in the strip |
/// | `open_channel` | `name` | clicks a channel row in the sidebar |
/// | `tap` | `target`, `index` | primary click |
/// | `right_click` | `target`, `index` | secondary click (context menus) |
/// | `long_press` | `target`, `index` | long press (mobile-style actions) |
/// | `tap_at` | `x`,`y` or `of`+`align`+`dx`,`dy` | click a POINT, for empty space |
/// | `right_click_at` | same as `tap_at` | secondary click on a point |
/// | `enter_text` | `value`, `target` (default `field`) | types into a field |
/// | `key` | `value` (`escape`, `enter`, `tab`, ...) | one key press |
/// | `scroll` | `target`, `dy`, `dx` | drags a scrollable |
/// | `wait` | `ms` or `frames` | pumps frames |
/// | `shot` | `name` | writes a PNG |
/// | `dump` | `name` | writes the navigation map + provider state |
/// | `expect_text` | `value` | fails unless the text is on screen |
/// | `expect_no_text` | `value` | fails when the text IS on screen |
/// | `expect_count` | `target`, `value` | fails unless the count matches |
/// | `log` | `message` | a note in the results |
/// | `quit` | | ends a live session |
///
/// Targets use the [ProbeTargets] grammar. Any step may carry `"soft": true`
/// to record a failure and keep going.
class ProbeRunner {
  ProbeRunner({
    required this.tester,
    required this.outDir,
    required this.shotKey,
    required this.container,
    this.autoShot = false,
  });

  final WidgetTester tester;
  final String outDir;
  final GlobalKey shotKey;
  final ProviderContainer? container;

  /// Screenshot after every step. On in the live loop, where looking at the
  /// result IS the point; off for scripts, which ask for shots by name.
  final bool autoShot;

  final List<Map<String, dynamic>> results = [];
  int _seq = 0;

  bool get failed => results.any((r) => r['ok'] == false);

  // ---------------------------------------------------------------------------
  // Frames and pictures
  // ---------------------------------------------------------------------------

  /// Pumps [frames] frames.
  ///
  /// Never `pumpAndSettle`: the shimmer, typewriter and GIF tickers are
  /// perpetual, so "wait until nothing animates" is a deadlock by
  /// construction.
  Future<void> settle({
    int frames = 30,
    Duration step = const Duration(milliseconds: 50),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  /// Writes a PNG of the current frame to `<outDir>/<name>.png`.
  ///
  /// Deliberately NOT `binding.takeScreenshot`: that goes through the
  /// integration_test plugin's `captureScreenshot` channel, which has no
  /// Windows desktop implementation and throws MissingPluginException.
  /// Painting the root RepaintBoundary works everywhere and needs no driver
  /// support. Platform views (WebRTC video surfaces) do not appear in the
  /// result, which is fine for chrome, menus and dialogs.
  Future<String?> shot(String name) async {
    final boundary =
        shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    String? path;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final dir = Directory(outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('$outDir/$name.png');
      file.writeAsBytesSync(data.buffer.asUint8List());
      path = file.path;
      debugPrint('[ui-probe] screenshot -> ${file.absolute.path}');
    });
    return path;
  }

  // ---------------------------------------------------------------------------
  // Script mode
  // ---------------------------------------------------------------------------

  /// Runs [steps] in order. Stops at the first hard failure; a step marked
  /// `"soft": true` records its failure and lets the rest run.
  Future<void> runScript(List<dynamic> steps) async {
    for (final raw in steps) {
      if (raw is! Map) {
        _record({'op': '?'}, false, 'step is not an object: $raw');
        break;
      }
      final step = raw.cast<String, dynamic>();
      final result = await runStep(step);
      if (result['ok'] == false && step['soft'] != true) {
        debugPrint('[ui-probe] stopping: step ${result['i']} failed');
        break;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Live mode
  // ---------------------------------------------------------------------------

  /// Reads commands from `<outDir>/inbox.jsonl` as they are appended and
  /// answers into `outbox.jsonl`, so a session can drive the app one command
  /// at a time: write a command, look at the screenshot, decide the next one.
  ///
  /// Ends on `{"op":"quit"}` or after [idleTimeout] with no new command, so a
  /// forgotten session cannot hold the app open forever.
  Future<void> runLive({
    Duration idleTimeout = const Duration(minutes: 20),
  }) async {
    final inbox = File('$outDir/inbox.jsonl');
    if (!inbox.existsSync()) inbox.writeAsStringSync('');
    final outbox = File('$outDir/outbox.jsonl');
    outbox.writeAsStringSync('');

    _appendJson(outbox, {
      'op': 'ready',
      'ok': true,
      'message': 'live loop is listening on ${inbox.path}',
    });
    // A marker a shell can wait on without parsing anything.
    File('$outDir/live-ready').writeAsStringSync(
        DateTime.now().toIso8601String());
    debugPrint('[ui-probe] LIVE. append commands to ${inbox.absolute.path}');

    var consumed = 0;
    var lastActivity = DateTime.now();

    while (true) {
      final lines = inbox.existsSync() ? inbox.readAsLinesSync() : const [];
      var progressed = false;
      while (consumed < lines.length) {
        final line = lines[consumed].trim();
        if (line.isEmpty) {
          consumed++;
          continue;
        }
        Map<String, dynamic>? command;
        try {
          command = (jsonDecode(line) as Map).cast<String, dynamic>();
        } catch (e) {
          // The writer may be mid-append. Only the LAST line can be partial,
          // so wait for it to finish; anything earlier is genuinely malformed.
          if (consumed == lines.length - 1) break;
          consumed++;
          _appendJson(outbox, {'ok': false, 'message': 'bad JSON: $e', 'line': line});
          continue;
        }
        consumed++;
        progressed = true;
        final result = await runStep(command);
        _appendJson(outbox, result);
        if (command['op'] == 'quit') {
          debugPrint('[ui-probe] live loop: quit');
          return;
        }
      }

      if (progressed) lastActivity = DateTime.now();
      if (DateTime.now().difference(lastActivity) > idleTimeout) {
        debugPrint('[ui-probe] live loop: idle for ${idleTimeout.inMinutes}m, '
            'ending');
        _appendJson(outbox, {
          'op': 'timeout',
          'ok': true,
          'message': 'idle for ${idleTimeout.inMinutes} minutes',
        });
        return;
      }
      // Keep the app alive and animating while waiting for the next command.
      await settle(frames: 4, step: const Duration(milliseconds: 50));
    }
  }

  void _appendJson(File file, Map<String, dynamic> value) {
    file.writeAsStringSync('${jsonEncode(value)}\n', mode: FileMode.append);
  }

  // ---------------------------------------------------------------------------
  // One step
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> runStep(Map<String, dynamic> step) async {
    final op = '${step['op']}';
    final started = DateTime.now();
    var ok = true;
    var message = '';
    final extra = <String, dynamic>{};

    try {
      message = await _dispatch(op, step, extra);
    } on _ProbeFailure catch (e) {
      ok = false;
      message = e.message;
    } catch (e, stack) {
      ok = false;
      message = '$e';
      debugPrint('[ui-probe] step "$op" threw: $e\n$stack');
    }

    final result = _record(step, ok, message, extra: extra);
    final index = result['i'];

    if (!ok) {
      // "Not found" on its own is not worth reading. Leave behind the picture
      // and the map of what WAS there, which is what names the mistake.
      result['shot'] = await shot('fail-$index-$op');
      await _safeDump('fail-$index');
    } else if (autoShot && _visualOp(op)) {
      result['shot'] = await shot('live-$index-$op');
    }
    result['ms'] = DateTime.now().difference(started).inMilliseconds;
    _rewriteResults();
    return result;
  }

  /// Ops worth an automatic screenshot. `dump`, `log` and `expect_*` change
  /// nothing, so a shot of them only duplicates the previous frame, and `shot`
  /// has already written one under the name that was asked for.
  bool _visualOp(String op) => !const {
        'dump',
        'log',
        'shot',
        'expect_text',
        'expect_no_text',
        'expect_count',
        'quit',
      }.contains(op);

  Future<String> _dispatch(
      String op, Map<String, dynamic> step, Map<String, dynamic> extra) async {
    switch (op) {
      case 'open_server':
        return _openServer('${step['name']}');

      case 'open_channel':
        final name = '${step['name']}';
        final finder = _finder(step, fallbackTarget: 'channel:$name');
        await tester.tap(finder, warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 30);
        return 'opened channel "$name"';

      case 'tap':
        final finder = _finder(step);
        await tester.tap(finder, warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 25);
        return 'tapped ${step['target']}';

      case 'right_click':
        final finder = _finder(step);
        await tester.tap(finder,
            buttons: kSecondaryButton, warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 25);
        return 'right-clicked ${step['target']}';

      case 'long_press':
        final finder = _finder(step);
        await tester.longPress(finder, warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 25);
        return 'long-pressed ${step['target']}';

      case 'tap_at':
      case 'right_click_at':
        final point = _point(step);
        if (op == 'tap_at') {
          await tester.tapAt(point);
        } else {
          final gesture = await tester.startGesture(point,
              buttons: kSecondaryButton);
          await gesture.up();
        }
        await settle(frames: step['frames'] as int? ?? 25);
        return '$op at ${point.dx.round()},${point.dy.round()}';

      case 'enter_text':
        final finder = _finder(step, fallbackTarget: 'field');
        await tester.enterText(finder, '${step['value']}');
        await settle(frames: step['frames'] as int? ?? 10);
        return 'typed "${step['value']}"';

      case 'key':
        final key = _key('${step['value']}');
        await tester.sendKeyEvent(key);
        await settle(frames: step['frames'] as int? ?? 15);
        return 'pressed ${step['value']}';

      case 'scroll':
        final finder = _finder(step);
        final dx = (step['dx'] as num?)?.toDouble() ?? 0;
        final dy = (step['dy'] as num?)?.toDouble() ?? -200;
        await tester.drag(finder, Offset(dx, dy), warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 20);
        return 'scrolled ${step['target']} by $dx,$dy';

      case 'wait':
      case 'pump':
        final ms = step['ms'] as int?;
        final frames = step['frames'] as int? ?? (ms == null ? 30 : ms ~/ 50);
        await settle(frames: frames);
        return 'waited ${frames * 50}ms';

      case 'shot':
        final name = '${step['name'] ?? 'shot'}';
        final path = await shot(name);
        extra['shot'] = path;
        return path == null ? 'no boundary to paint' : 'wrote $path';

      case 'dump':
        final name = '${step['name'] ?? 'map'}';
        final map = await _safeDump(name);
        extra['overlays'] = map?['overlays'];
        return 'wrote map-$name.json and map-$name.md';

      case 'expect_text':
        final value = '${step['value']}';
        if (find.text(value, findRichText: true).evaluate().isNotEmpty) {
          return 'found "$value"';
        }
        if (find.textContaining(value, findRichText: true).evaluate().isNotEmpty) {
          return 'found "$value" (as a substring)';
        }
        throw _ProbeFailure('"$value" is not on screen');

      case 'expect_no_text':
        final value = '${step['value']}';
        final hits =
            find.textContaining(value, findRichText: true).evaluate().length;
        if (hits > 0) {
          throw _ProbeFailure('"$value" is still on screen ($hits matches)');
        }
        return '"$value" is gone';

      case 'expect_count':
        final target = '${step['target']}';
        final want = step['value'] as int? ?? 0;
        final got = ProbeTargets.resolve(target).evaluate().length;
        if (got != want) {
          throw _ProbeFailure('$target matched $got widgets, expected $want');
        }
        return '$target matched $got';

      case 'log':
        return '${step['message'] ?? ''}';

      case 'quit':
        return 'bye';

      default:
        throw _ProbeFailure('unknown op "$op"');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Resolves a step's target, failing with what the screen DOES hold rather
  /// than with a bare "not found".
  Finder _finder(Map<String, dynamic> step, {String? fallbackTarget}) {
    final target = (step['target'] as String?) ?? fallbackTarget;
    if (target == null) {
      throw _ProbeFailure('step needs a "target"');
    }
    final finder = ProbeTargets.resolve(target);
    final count = finder.evaluate().length;
    if (count == 0) {
      throw _ProbeFailure('nothing matches "$target".\n${_nearby(target)}');
    }
    final index = step['index'] as int? ?? 0;
    if (index >= count) {
      throw _ProbeFailure('"$target" matched $count widgets, no index $index');
    }
    return finder.at(index);
  }

  /// What a failed target might have meant: the visible text and labels that
  /// are actually there, so the next attempt is informed rather than another
  /// guess.
  String _nearby(String target) {
    final value = target.contains(':') ? target.split(':').last : target;
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final close = texts
        .where((t) => t.toLowerCase().contains(value.toLowerCase()))
        .toList();
    final buffer = StringBuffer();
    if (close.isNotEmpty) {
      buffer.writeln('Text containing "$value": ${close.join(" | ")}');
    }
    final shown = texts.take(60).toList();
    buffer.write('Visible text (${texts.length}): ${shown.join(" | ")}'
        '${texts.length > shown.length ? " ..." : ""}');
    return buffer.toString();
  }

  /// A point to click, either absolute (`x`,`y`) or relative to a widget
  /// (`of` + `align` + `dx`,`dy`). The relative form is how empty space is
  /// reached: the sidebar background menu has no widget of its own.
  Offset _point(Map<String, dynamic> step) {
    final dx = (step['dx'] as num?)?.toDouble() ?? 0;
    final dy = (step['dy'] as num?)?.toDouble() ?? 0;
    final of = step['of'] as String?;
    if (of == null) {
      final x = (step['x'] as num?)?.toDouble();
      final y = (step['y'] as num?)?.toDouble();
      if (x == null || y == null) {
        throw _ProbeFailure('point needs x and y, or of + align');
      }
      return Offset(x, y);
    }
    final finder = ProbeTargets.resolve(of);
    if (finder.evaluate().isEmpty) {
      throw _ProbeFailure('nothing matches "$of".\n${_nearby(of)}');
    }
    final rect = tester.getRect(finder.at(step['index'] as int? ?? 0));
    final anchor = switch ('${step['align'] ?? 'center'}') {
      'topLeft' => rect.topLeft,
      'topRight' => rect.topRight,
      'bottomLeft' => rect.bottomLeft,
      'bottomRight' => rect.bottomRight,
      'topCenter' => rect.topCenter,
      'bottomCenter' => rect.bottomCenter,
      'centerLeft' => rect.centerLeft,
      'centerRight' => rect.centerRight,
      _ => rect.center,
    };
    return anchor + Offset(dx, dy);
  }

  LogicalKeyboardKey _key(String name) {
    const keys = <String, LogicalKeyboardKey>{
      'escape': LogicalKeyboardKey.escape,
      'enter': LogicalKeyboardKey.enter,
      'tab': LogicalKeyboardKey.tab,
      'space': LogicalKeyboardKey.space,
      'backspace': LogicalKeyboardKey.backspace,
      'delete': LogicalKeyboardKey.delete,
      'arrowUp': LogicalKeyboardKey.arrowUp,
      'arrowDown': LogicalKeyboardKey.arrowDown,
      'arrowLeft': LogicalKeyboardKey.arrowLeft,
      'arrowRight': LogicalKeyboardKey.arrowRight,
      'home': LogicalKeyboardKey.home,
      'end': LogicalKeyboardKey.end,
      'f10': LogicalKeyboardKey.f10,
      'contextMenu': LogicalKeyboardKey.contextMenu,
    };
    final key = keys[name];
    if (key == null) {
      throw _ProbeFailure('unknown key "$name". Known: ${keys.keys.join(", ")}');
    }
    return key;
  }

  /// Clicks the server icon whose accessibility label is [name].
  Future<String> _openServer(String name) async {
    final finder = ProbeTargets.resolve('server:$name');
    if (finder.evaluate().isEmpty) {
      final labels = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((w) => w.properties.label)
          .whereType<String>()
          .where((l) => l.trim().isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      throw _ProbeFailure('server "$name" not found.\n'
          'Semantics labels present (${labels.length}): ${labels.join(" | ")}');
    }
    await tester.tap(finder.first, warnIfMissed: false);
    await settle(frames: 40);
    return 'opened server "$name"';
  }

  Future<Map<String, dynamic>?> _safeDump(String name) async {
    try {
      return await ProbeDump.write(
        tester: tester,
        name: name,
        outDir: outDir,
        container: container,
      );
    } catch (e) {
      debugPrint('[ui-probe] dump "$name" failed: $e');
      return null;
    }
  }

  Map<String, dynamic> _record(
    Map<String, dynamic> step,
    bool ok,
    String message, {
    Map<String, dynamic> extra = const {},
  }) {
    final result = <String, dynamic>{
      'i': _seq++,
      'op': step['op'],
      if (step['target'] != null) 'target': step['target'],
      if (step['name'] != null) 'name': step['name'],
      if (step['id'] != null) 'id': step['id'],
      'ok': ok,
      'message': message,
      ...extra,
      // Cheap, and it answers the question every command raises: did that open
      // a menu, and what is in it?
      'overlays': _overlaySummary(),
    };
    results.add(result);
    debugPrint('[ui-probe] ${ok ? "ok  " : "FAIL"} '
        '${result['i']} ${step['op']} ${step['target'] ?? step['name'] ?? ''}'
        '${message.isEmpty ? '' : ' - ${message.split("\n").first}'}');
    return result;
  }

  Map<String, dynamic> _overlaySummary() {
    final menus = ProbeTargets.byTypeName('_HollowMenuHost');
    final rows = menus.evaluate().isEmpty
        ? const <String>[]
        : find
            .descendant(of: menus, matching: find.byType(Text))
            .evaluate()
            .map((e) => (e.widget as Text).data ?? '')
            .where((s) => s.trim().isNotEmpty)
            .toList();
    return {
      'dialog': ProbeTargets.byTypeName('HollowDialog').evaluate().isNotEmpty,
      'menu': menus.evaluate().isNotEmpty,
      if (rows.isNotEmpty) 'menuRows': rows,
    };
  }

  /// Rewrites the whole results file after each step, so a run that is killed
  /// mid-way still leaves a complete record of what it managed to do.
  void _rewriteResults() {
    final dir = Directory(outDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$outDir/results.jsonl').writeAsStringSync(
        results.map(jsonEncode).join('\n') + (results.isEmpty ? '' : '\n'));
  }
}

class _ProbeFailure implements Exception {
  _ProbeFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

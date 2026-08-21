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
/// | `hover` | `target`, `index` | parks a mouse pointer on it (hover bars) |
/// | `hover_at` | same as `tap_at` | parks a mouse pointer on a POINT |
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
/// | `look` | `filter`, `max` | what is on screen, IN the answer |
/// | `wait_for` | `target` or `gone`, `timeout_ms`, `count` | polls until it holds |
/// | `capture` | `as`, `target` or `from` | reads a value out of the app |
/// | `log` | `message` | a note in the results |
/// | `quit` | | ends a live session |
///
/// Targets use the [ProbeTargets] grammar. Any step may carry `"soft": true`
/// to record a failure and keep going, and a pointer step may carry
/// `"allowMiss": true` to skip the check that its click actually lands on the
/// widget it found (see [ProbeRunner._requireHittable]).
///
/// Every string in a step is `${VAR}`-substituted before it runs, from values
/// captured by [captured] first and the environment second. That is what lets
/// a fleet scenario pull an invite link out of one instance and paste it into
/// another (see `scripts/fleet.ps1`).
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

  /// Values pulled out of the app by the `capture` op, substituted into later
  /// steps as `${NAME}`. In a fleet run the orchestrator also reads them out
  /// of the answer and substitutes them into the OTHER instance's steps, which
  /// is how an invite link crosses from one app to another.
  final Map<String, String> captured = {};

  /// Which instance this is, when there is more than one (`UI_PROBE_PEER`).
  /// Stamped on every answer so a tail of several outboxes stays readable.
  final String? peer = Platform.environment['UI_PROBE_PEER'];

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

  Future<Map<String, dynamic>> runStep(Map<String, dynamic> rawStep) async {
    final step = _substitute(rawStep).cast<String, dynamic>();
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
        'capture',
        'look',
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
        _requireHittable(finder, step);
        await tester.tap(finder, warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 25);
        return 'tapped ${step['target']}';

      case 'right_click':
        final finder = _finder(step);
        _requireHittable(finder, step);
        await tester.tap(finder,
            buttons: kSecondaryButton, warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 25);
        return 'right-clicked ${step['target']}';

      case 'long_press':
        final finder = _finder(step);
        _requireHittable(finder, step);
        await tester.longPress(finder, warnIfMissed: false);
        await settle(frames: step['frames'] as int? ?? 25);
        return 'long-pressed ${step['target']}';

      case 'hover':
        final finder = _finder(step);
        await _hover(tester.getCenter(finder));
        await settle(frames: step['frames'] as int? ?? 25);
        return 'hovering ${step['target']}';

      case 'hover_at':
        final point = _point(step);
        await _hover(point);
        await settle(frames: step['frames'] as int? ?? 25);
        return 'hovering ${point.dx.round()},${point.dy.round()}';

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

      case 'view':
        return _view(step);

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

      case 'look':
        return _look(step);

      case 'wait_for':
        return _waitFor(step);

      case 'capture':
        return _capture(step, extra);

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

  /// What is on screen right now, as the answer's message.
  ///
  /// The same list `dump` writes to disk, filtered to the things a step can
  /// actually address and small enough to read in a terminal. `dump` is still
  /// the right tool for a real diagnosis - it carries the provider state and
  /// the layout outline - but most of the time the only question is "what do I
  /// click next", and answering that by writing a file and then reading and
  /// grepping it costs a whole extra round trip. Batch it after the step that
  /// changed the screen: `[{"op":"tap",...},{"op":"look"}]`.
  ///
  /// `filter` narrows to targets or labels containing a substring; `max` caps
  /// the control list (default 45).
  /// Resizes the FRAMEWORK viewport, which is what "the user maximized the
  /// window" looks like to every widget: MediaQuery changes, the tree relays
  /// out, and anything that captured a coordinate at open time (an anchored
  /// popup) has to notice. The OS window is left alone deliberately — driving
  /// window_manager against a window the probe never took through main()'s
  /// setAsFrameless dance takes the whole process down with no Dart error.
  Future<String> _view(Map<String, dynamic> step) async {
    final frames = step['frames'] as int? ?? 25;
    if (step['reset'] == true) {
      tester.view.resetPhysicalSize();
      await settle(frames: frames);
      return 'view reset';
    }
    final width = (step['width'] as num?)?.toDouble();
    final height = (step['height'] as num?)?.toDouble();
    if (width == null || height == null) {
      throw _ProbeFailure('view needs "width" and "height", or "reset": true');
    }
    final dpr = tester.view.devicePixelRatio;
    tester.view.physicalSize = Size(width * dpr, height * dpr);
    await settle(frames: frames);
    return 'view is ${width.round()}x${height.round()} logical';
  }

  Future<String> _look(Map<String, dynamic> step) async {
    final filter = (step['filter'] as String?)?.toLowerCase();
    final max = step['max'] as int? ?? 45;
    final entries =
        ProbeDump.collect(tester, tester.view.physicalSize / tester.view.devicePixelRatio);

    // The kinds a step can act on. `text` is handled separately because half
    // the app's rows ARE their label; `keyed` and `surface` are out because
    // there are hundreds of them and a scenario almost never wants one.
    const actionable = {
      'semantics', 'pressable', 'button', 'field', 'input', 'tooltip', 'icon',
    };
    final controls = <String>[];
    final texts = <String>[];
    for (final entry in entries) {
      final target = entry['target'] as String?;
      if (target == null || target.isEmpty) continue;
      final label = '${entry['label'] ?? ''}';
      if (filter != null &&
          !target.toLowerCase().contains(filter) &&
          !label.toLowerCase().contains(filter)) {
        continue;
      }
      final kind = '${entry['kind']}';
      final count = entry['matches'] as int? ?? 1;
      final line = count > 1 ? '$target  x$count' : target;
      if (actionable.contains(kind)) {
        if (!controls.contains(line)) controls.add(line);
      } else if (kind == 'text') {
        if (!texts.contains(label) && label.trim().isNotEmpty) texts.add(label);
      }
    }

    final overlays = _overlaySummary();
    final buffer = StringBuffer();
    buffer.writeln(overlays['dialog'] == true
        ? 'dialog OPEN'
        : 'no dialog');
    final rows = overlays['menuRows'] as List?;
    if (rows != null && rows.isNotEmpty) {
      buffer.writeln('menu: ${rows.join(" | ")}');
    }
    buffer.writeln('controls (${controls.length}'
        '${controls.length > max ? ', first $max' : ''}):');
    for (final line in controls.take(max)) {
      buffer.writeln('  $line');
    }
    if (texts.isNotEmpty) {
      buffer.write('text (${texts.length}): ${texts.take(60).join(" | ")}');
    }
    return buffer.toString().trimRight();
  }

  /// Polls until a condition holds, instead of guessing a fixed wait.
  ///
  /// A fixed `wait` is fine when one app talks to itself. Put a relay round
  /// trip in the middle and it becomes a coin flip: too short and it fails on
  /// a slow run, too long and every scenario crawls. This is the op that makes
  /// a fleet suite trustworthy rather than flaky.
  ///
  /// * `target` — wait until it is on screen
  /// * `gone` — wait until it is NOT on screen
  /// * `count` — with `target`, wait until it matches exactly that many
  ///
  /// Note "gone" means BECAME absent: it returns the moment the condition
  /// holds, so it proves a disappearance, not a permanent absence. To assert
  /// something never shows up, `wait` a fixed time and then `expect_no_text`.
  Future<String> _waitFor(Map<String, dynamic> step) async {
    final target = step['target'] as String?;
    final gone = step['gone'] as String? ?? step['absent'] as String?;
    if (target == null && gone == null) {
      throw _ProbeFailure('wait_for needs a "target" or a "gone"');
    }
    final want = step['count'] as int?;
    final timeout = Duration(milliseconds: step['timeout_ms'] as int? ?? 15000);
    final spec = target ?? gone!;
    final started = DateTime.now();
    var polls = 0;
    var last = -1;

    while (true) {
      polls++;
      last = ProbeTargets.resolve(spec).evaluate().length;
      final held = gone != null
          ? last == 0
          : (want == null ? last > 0 : last == want);
      if (held) {
        final ms = DateTime.now().difference(started).inMilliseconds;
        return gone != null
            ? '"$gone" went away after ${ms}ms ($polls polls)'
            : '"$target" appeared after ${ms}ms ($polls polls, $last match'
                '${last == 1 ? '' : 'es'})';
      }
      if (DateTime.now().difference(started) >= timeout) break;
      // ~200ms per poll: fast enough to feel immediate, slow enough that a
      // 30s wait is 150 finder evaluations rather than thousands.
      await settle(frames: 4, step: const Duration(milliseconds: 50));
    }

    final ms = DateTime.now().difference(started).inMilliseconds;
    if (gone != null) {
      throw _ProbeFailure('"$gone" was still on screen after ${ms}ms '
          '($last matches).');
    }
    throw _ProbeFailure(
        '"$target" did not ${want == null ? 'appear' : 'reach $want matches'} '
        'within ${ms}ms (last count $last).\n${_nearby(target!)}');
  }

  /// Reads a value out of the app and remembers it as `${as}`.
  ///
  /// * `target` (default) — the text of the matched widget and its subtree
  /// * `from: "provider"` + `key` — a value from the dump's provider snapshot
  /// * `from: "clipboard"` — whatever the app last copied
  /// * `regex` — narrows the value to the first capture group
  ///
  /// The value also comes back in the answer, which is how a fleet run moves
  /// an invite link from the instance that generated it to the one that has
  /// to paste it.
  Future<String> _capture(
      Map<String, dynamic> step, Map<String, dynamic> extra) async {
    final name = step['as'] as String?;
    if (name == null) throw _ProbeFailure('capture needs an "as"');
    final from = '${step['from'] ?? 'widget'}';

    String value;
    if (from == 'provider') {
      // The same snapshot the dump prints, so anything readable there is
      // capturable here: `peerId` (this instance's identity, which is how a
      // friend request finds it), `selectedChannel`, `connection`, and the
      // rest. Reading state beats reading the screen whenever the screen only
      // shows a truncated form of it.
      final key = step['key'] as String?;
      if (key == null) {
        throw _ProbeFailure('capture from a provider needs a "key"');
      }
      final snapshot = ProbeDump.providerSnapshot(container);
      final held = snapshot[key];
      if (held == null) {
        final known = snapshot.keys.toList()..sort();
        throw _ProbeFailure('no provider value "$key". '
            'Readable now: ${known.join(", ")}');
      }
      value = held is String ? held : jsonEncode(held);
    } else if (from == 'clipboard') {
      final data = await tester.runAsync(
          () => Clipboard.getData(Clipboard.kTextPlain));
      value = data?.text ?? '';
      if (value.isEmpty) {
        throw _ProbeFailure('the clipboard is empty (or unreadable from the '
            'test binding). Capture from a widget instead.');
      }
    } else {
      final finder = _finder(step);
      value = _textOf(finder);
      if (value.isEmpty) {
        throw _ProbeFailure(
            '"${step['target']}" holds no text to capture.\n'
            '${_nearby('${step['target']}')}');
      }
    }

    final pattern = step['regex'] as String?;
    if (pattern != null) {
      final match = RegExp(pattern).firstMatch(value);
      if (match == null) {
        throw _ProbeFailure('regex "$pattern" does not match "$value"');
      }
      value = match.groupCount >= 1 ? (match.group(1) ?? '') : match.group(0)!;
    }

    captured[name] = value;
    extra['captured'] = {name: value};
    extra['value'] = value;
    return 'captured $name = "$value"';
  }

  /// All the text a widget carries, itself or anywhere below it.
  String _textOf(Finder finder) {
    String? direct(Widget widget) {
      if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText();
      if (widget is SelectableText) {
        return widget.data ?? widget.textSpan?.toPlainText();
      }
      if (widget is EditableText) return widget.controller.text;
      if (widget is TextField) return widget.controller?.text;
      return null;
    }

    final self = direct(finder.evaluate().first.widget);
    if (self != null && self.isNotEmpty) return self;

    final parts = <String>[];
    for (final element in find
        .descendant(of: finder, matching: find.byWidgetPredicate((_) => true))
        .evaluate()) {
      final text = direct(element.widget);
      if (text != null && text.trim().isNotEmpty && !parts.contains(text)) {
        parts.add(text);
      }
    }
    return parts.join('\n');
  }

  /// Replaces `${NAME}` in every string of a step, from [captured] first and
  /// the environment second. An unknown name is left alone, so a literal
  /// `${...}` in a message survives rather than turning into an empty string.
  dynamic _substitute(dynamic value) {
    if (value is String) {
      return value.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (match) {
        final name = match.group(1)!;
        return captured[name] ??
            Platform.environment[name] ??
            Platform.environment['UI_PROBE_$name'] ??
            match.group(0)!;
      });
    }
    if (value is Map) {
      return {for (final e in value.entries) e.key: _substitute(e.value)};
    }
    if (value is List) return value.map(_substitute).toList();
    return value;
  }

  /// Parks a mouse pointer at [point] and leaves it there.
  ///
  /// The message action bar, tooltips and every hover state only exist while a
  /// mouse is over the thing, and `tester.tap` sends a touch-like pointer that
  /// arrives and leaves. The gesture is deliberately NOT removed: the next
  /// step usually wants to click what the hover just revealed.
  Future<void> _hover(Offset point) async {
    final gesture = _hoverGesture ??=
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: point);
    await gesture.moveTo(point);
  }

  TestGesture? _hoverGesture;

  /// Fails when the point the tap will land on does not actually reach the
  /// widget that was found.
  ///
  /// `tester.tap` aims at the widget's CENTRE, computed from its render box —
  /// and a render box knows nothing about clipping. A list row scrolled half
  /// out of its viewport still reports its full height, so the centre lands
  /// past the clip, on whatever is painted there instead (a pinned footer
  /// button, usually). The tap then quietly does nothing and the step passes,
  /// which is the worst possible outcome for a tool whose entire job is to
  /// report what the app did. This turns that into a named failure.
  ///
  /// Pass `"allowMiss": true` on a step that deliberately clicks through
  /// something.
  void _requireHittable(Finder finder, Map<String, dynamic> step) {
    if (step['allowMiss'] == true) return;
    final target = finder.evaluate().first.renderObject;
    if (target is! RenderBox || !target.hasSize) return;

    final point = tester.getCenter(finder);
    final result = tester.hitTestOnBinding(point);
    for (final entry in result.path) {
      if (identical(entry.target, target)) return;
    }

    // Name what IS there instead, so the next attempt is informed.
    final blockers = <String>[];
    for (final entry in result.path) {
      final hit = entry.target;
      if (hit is! RenderBox) continue;
      for (final element in tester.allElements) {
        if (!identical(element.renderObject, hit)) continue;
        final description = _describeElement(element);
        if (description != null && !blockers.contains(description)) {
          blockers.add(description);
        }
        break;
      }
      if (blockers.length >= 4) break;
    }

    final what = blockers.isEmpty
        ? 'Nothing was hit there at all.'
        : 'What is hit there instead: ${blockers.join(" < ")}';
    throw _ProbeFailure(
        '"${step['target']}" is on screen but a click at its centre '
        '(${point.dx.round()},${point.dy.round()}) does not reach it: '
        'it is clipped, covered, or not hit-testable.\n'
        '$what\n'
        'Scroll it fully into view, target a different widget, or pass '
        '"allowMiss": true if the click is meant to land elsewhere.');
  }

  /// A short human name for a widget, for the blocker list above.
  String? _describeElement(Element element) {
    final widget = element.widget;
    if (widget is Text) return 'Text "${widget.data}"';
    if (widget is Semantics) {
      final label = widget.properties.label;
      if (label != null && label.isNotEmpty) return 'Semantics "$label"';
    }
    final name = widget.runtimeType.toString();
    if (name.startsWith('_Render') || name.startsWith('RenderObject')) {
      return null;
    }
    return name;
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
      if (peer != null) 'peer': peer,
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

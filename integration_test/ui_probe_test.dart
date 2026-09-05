import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/shop_unlock_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:integration_test/integration_test.dart';
import 'package:window_manager/window_manager.dart';

import 'probe/probe_runner.dart';

/// Drives the REAL app against a COPY of a real data directory, so a change
/// can be checked by looking at it rather than by asking a human to look at it.
///
/// Run it with `scripts/ui_probe.ps1`, which handles the data-dir copy, kills a
/// stale instance and points `HOLLOW_DATA_DIR` at the copy. Never run it
/// against a live data dir: it clicks real buttons and writes real CRDT ops.
///
/// ## Three ways in
///
/// * **A scenario file** — `UI_PROBE_SCENARIO_FILE=scripts/probe_scenarios/x.json`.
/// * **Inline steps** — `UI_PROBE_STEPS='[{"op":"dump","name":"home"}]'`.
/// * **Live** — `UI_PROBE_MODE=live`, then append commands to
///   `build/ui_probe/inbox.jsonl` one at a time and read `outbox.jsonl`.
///
/// All three are ENVIRONMENT variables, never `--dart-define`: a dart-define is
/// compile-time, so it would put a rebuild between every iteration, which is
/// the whole thing this replaces.
///
/// With none of them set it boots, screenshots and dumps the navigation map,
/// which is the cheapest useful run.
///
/// ## What this catches that widget tests do not
/// The widget tests mock FFI, so every bug that lives in the seam between Dart
/// state and the real Rust/SQLCipher round trip is invisible to them - which is
/// most of what has actually gone wrong on issue #61: optimistic writes,
/// reload races, a provider ref that was disposed a frame earlier. Here the DB,
/// the CRDT and the providers are all real.
///
/// ## What it still does NOT cover
/// One instance, so nothing here proves delivery: no second peer, no sync.
/// That stays with the Rust multi-node harness. Platform views (WebRTC video)
/// do not render into the screenshots.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final env = Platform.environment;
  final outDir = env['UI_PROBE_OUT'] ?? 'build/ui_probe';
  final mode = env['UI_PROBE_MODE'] ?? 'script';
  final idleMinutes = int.tryParse(env['UI_PROBE_IDLE_MINUTES'] ?? '') ?? 20;

  // RustLib.init() MUST run here, not inside the test body. It does real
  // async work (loading the native lib and handshaking), and the test body
  // runs in a zone where that never completes, so an init from inside boot()
  // silently leaves every FFI-backed provider throwing "not initialized" and
  // the first widget that reads one takes the whole run down.
  setUpAll(() async {
    await RustLib.init();
    // The real app primes this in main() before runApp; the probe builds the
    // widget tree itself, so without this the Hollow Shop button never
    // exists here (a store build and an unprimed build look the same).
    await ShopAvailability.prime();
    // The shop also ships put away: it appears only after seven taps on the
    // version row in Settings > About, and this tree has never seen them. The
    // store is not open yet here, so the setting cannot be written; seeding
    // the notifier is the one hook early enough, and it survives the shell's
    // own load(). UI_PROBE_SHOP_LOCKED=1 skips the seed, which is what
    // scripts/probe_scenarios/shop_hidden.json runs on.
    if ((env['UI_PROBE_SHOP_LOCKED'] ?? '') != '1') {
      ShopUnlockNotifier.debugSeed(true);
    }
    // The probe boots HollowApp directly and never runs main(), so anything
    // main() set up is missing unless it is set up here. Deliberately only
    // this call: setAsFrameless and the size/show dance belong to a real
    // launch, and the probe wants an ordinary window it can tile next to its
    // siblings.
    //
    // KNOWN LIMITATION, and this call does NOT fix it: the annotation toggle
    // (the pencil in the title bar) still takes the whole PROCESS down here,
    // with no Dart exception and nothing in any log. AnnotationOverlay drives
    // maximize/setBackgroundColor/setAlwaysOnTop against a window that never
    // went through main()'s waitUntilReadyToShow + setAsFrameless, and the
    // native side does not survive it. It works in the real app. Do not aim a
    // scenario at it; in a fleet run it looks like an instance that simply
    // stops answering.
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        await windowManager.ensureInitialized();
      } catch (e) {
        debugPrint('[ui-probe] window_manager init failed: $e');
      }
    }
  });

  // The app's own log, written from inside rather than by redirecting the
  // process's stdout.
  //
  // Redirection was the obvious way and it is a trap: PowerShell's
  // -RedirectStandardOutput flips Start-Process into inherit-handles mode, so
  // every launched instance keeps a duplicate of the launcher's stdout pipe,
  // and `fleet.ps1 -Live | anything` then never returns even though the script
  // finished. Measured: 1s launching plain, 45s (the timeout) with redirection.
  // Overriding debugPrint costs nothing, cannot leak a handle, and catches the
  // same lines - every [ui-probe] step and every Flutter error dump.
  final logFile = File('$outDir/stdout.log');
  final previousDebugPrint = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    previousDebugPrint(message, wrapWidth: wrapWidth);
    try {
      final dir = Directory(outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      logFile.writeAsStringSync('${message ?? ''}\n', mode: FileMode.append);
    } catch (_) {
      // A log that cannot be written must never be the thing that fails a run.
    }
  };

  // An unhandled app exception ends the test body, and the body IS the app, so
  // the process exits and takes the reason with it. In a fleet run that shows
  // up as one instance that silently never answers again. Writing every error
  // out as it happens means the reason survives the death, and the orchestrator
  // can print it instead of a bare timeout.
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    try {
      final dir = Directory(outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('$outDir/errors.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()} ${details.exceptionAsString()}\n'
        '${details.stack}\n\n',
        mode: FileMode.append,
      );
    } catch (_) {
      // Never let the error reporter be the thing that fails the run.
    }
    previousOnError?.call(details);
  };

  /// Root boundary the screenshots are painted from.
  final shotKey = GlobalKey();

  /// Kept so it can be disposed before the end-of-test checks; the framework
  /// fails a run that leaves a SemanticsHandle alive.
  SemanticsHandle? semanticsHandle;

  testWidgets('ui probe', (tester) async {
    // The container is ours rather than ProviderScope's so the dump can read
    // app state directly. UncontrolledProviderScope is what ProviderScope
    // builds internally, so the app cannot tell the difference.
    final container = ProviderContainer();
    final runner = ProbeRunner(
      tester: tester,
      outDir: outDir,
      shotKey: shotKey,
      container: container,
      autoShot: mode == 'live',
    );

    // find.bySemanticsLabel needs the semantics tree built, and semantics is
    // the only text identity a server icon has.
    semanticsHandle = tester.ensureSemantics();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: UncontrolledProviderScope(
          container: container,
          child: const HollowApp(),
        ),
      ),
    );
    // Identity unlock, DB open and the first channel load all happen here.
    await runner.settle(frames: 80, step: const Duration(milliseconds: 100));
    await runner.shot('00-boot');

    final steps = _loadSteps(env);
    if (mode == 'live') {
      debugPrint('[ui-probe] mode=live, idle timeout ${idleMinutes}m');
      if (steps != null) await runner.runScript(steps);
      await runner.runLive(idleTimeout: Duration(minutes: idleMinutes));
    } else if (steps != null) {
      await runner.runScript(steps);
    } else {
      // No scenario: still leave something worth having.
      await runner.runStep({'op': 'dump', 'name': 'boot'});
    }

    // Stop the app's decorative tickers.
    //
    // SharedTickers is a process-wide singleton that outlives the widget tree,
    // and the framework fails any run that leaves a Ticker scheduled after
    // teardown. It cannot be frozen up front: the settings provider loads
    // asynchronously and re-enables motion once the DB opens, well after boot.
    // So the freeze belongs at the END of the body, not in tearDown, which
    // runs after the framework has already made its check.
    ReduceMotionController.instance.setMode(ReduceMotionMode.on);
    semanticsHandle?.dispose();
    semanticsHandle = null;
    await tester.pump();
    // The container is deliberately NOT disposed. The widget tree is still
    // mounted here, and the app has async work in flight (channel history
    // loads, avatar fetches) that reads providers when it lands; disposing the
    // container out from under it throws "read from a ProviderContainer that
    // was already disposed" and fails a run whose steps all passed. The
    // process is about to exit, so there is nothing to reclaim.

    final failures = runner.results.where((r) => r['ok'] == false).toList();
    debugPrint('[ui-probe] ${runner.results.length} steps, '
        '${failures.length} failed');
    if (failures.isNotEmpty) {
      fail('${failures.length} of ${runner.results.length} steps failed:\n'
          '${failures.map((f) => '  #${f['i']} ${f['op']}: ${f['message']}').join('\n')}\n'
          'Artifacts in $outDir (fail-*.png, map-fail-*.md, results.jsonl).');
    }
  });
}

/// The step list, from a file or from the environment, or null when neither
/// was given.
List<dynamic>? _loadSteps(Map<String, String> env) {
  final file = env['UI_PROBE_SCENARIO_FILE'];
  String? raw;
  if (file != null && file.trim().isNotEmpty) {
    final handle = File(file);
    if (!handle.existsSync()) {
      throw StateError('UI_PROBE_SCENARIO_FILE not found: $file');
    }
    raw = handle.readAsStringSync();
  } else {
    final inline = env['UI_PROBE_STEPS'];
    if (inline != null && inline.trim().isNotEmpty) raw = inline;
  }
  if (raw == null) return null;

  // `${SERVER}` and friends, so one scenario file serves every server. Values
  // come from the environment, with or without the UI_PROBE_ prefix.
  final substituted = raw.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (match) {
    final name = match.group(1)!;
    final value = env[name] ?? env['UI_PROBE_$name'];
    if (value == null) return match.group(0)!;
    // Substituted INTO JSON text, so the value must be JSON-escaped: a Windows
    // path's backslashes would otherwise be read as string escapes.
    final encoded = jsonEncode(value);
    return encoded.substring(1, encoded.length - 1);
  });

  final decoded = jsonDecode(substituted);
  if (decoded is List) return decoded;
  if (decoded is Map && decoded['steps'] is List) {
    return decoded['steps'] as List<dynamic>;
  }
  throw StateError('a scenario must be a JSON array of steps, or an object '
      'with a "steps" array; got ${decoded.runtimeType}');
}

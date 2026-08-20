import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Drives the REAL app against a COPY of a real data directory, so a change
/// can be checked by looking at it rather than by asking a human to look at it.
///
/// Run it with `scripts/ui_probe.ps1`, which handles the data-dir copy, kills a
/// stale instance and points `HOLLOW_DATA_DIR` at the copy. Never run it
/// against a live data dir: it clicks real buttons and writes real CRDT ops.
///
/// ## What this catches that widget tests do not
/// The widget tests mock FFI, so every bug that lives in the seam between Dart
/// state and the real Rust/SQLCipher round trip is invisible to them — which is
/// most of what has actually gone wrong on issue #61: optimistic writes,
/// reload races, a provider ref that was disposed a frame earlier. Here the DB,
/// the CRDT and the providers are all real.
///
/// ## What it still does NOT cover
/// The node is not started, so nothing here reaches the relay: no live peers,
/// no sync, no delivery. This is a LOCAL-state probe. Anything distributed
/// still belongs in the Rust multi-node harness.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // RustLib.init() MUST run here, not inside the test body. It does real
  // async work (loading the native lib and handshaking), and the test body
  // runs in a zone where that never completes, so an init from inside boot()
  // silently leaves every FFI-backed provider throwing "not initialized" and
  // the first widget that reads one takes the whole run down.
  setUpAll(() async {
    await RustLib.init();
  });

  /// Kept so it can be disposed before the end-of-test checks; the framework
  /// fails a run that leaves a SemanticsHandle alive.
  SemanticsHandle? semanticsHandle;

  /// Stops the app's decorative tickers.
  ///
  /// [SharedTickers] is a process-wide singleton that outlives the widget tree,
  /// and the test framework fails any run that leaves a Ticker scheduled after
  /// teardown. It cannot be frozen up front: the settings provider loads
  /// asynchronously and re-enables motion once the DB opens, well after boot.
  /// So the freeze belongs at the END of the body, not in tearDown, which runs
  /// after the framework has already made its check.
  Future<void> freezeTickers(WidgetTester tester) async {
    ReduceMotionController.instance.setMode(ReduceMotionMode.on);
    semanticsHandle?.dispose();
    semanticsHandle = null;
    await tester.pump();
  }

  /// Name of the server to work in, e.g. `--dart-define=SERVER=test3`.
  const serverName = String.fromEnvironment('SERVER', defaultValue: 'test3');

  /// Which scenario to run, e.g. `--dart-define=SCENARIO=channel_menu`.
  const scenario = String.fromEnvironment('SCENARIO', defaultValue: 'boot');

  /// Pumps [frames] frames without `pumpAndSettle`.
  ///
  /// `pumpAndSettle` never returns in this app: the shimmer, typewriter and
  /// GIF tickers are perpetual animations, so "wait until nothing is
  /// animating" is a deadlock by construction.
  Future<void> settle(WidgetTester tester,
      {int frames = 30, Duration step = const Duration(milliseconds: 50)}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  /// Root boundary the screenshots are rendered from.
  final shotKey = GlobalKey();


  /// Writes a PNG of the current frame to `build/ui_probe/<name>.png`.
  ///
  /// Deliberately NOT `binding.takeScreenshot`: that goes through the
  /// integration_test plugin's `captureScreenshot` channel, which has no
  /// Windows desktop implementation and throws MissingPluginException. Painting
  /// the root RepaintBoundary ourselves works on every platform and needs no
  /// driver support. Platform views (WebRTC video surfaces) do not appear in
  /// the result, which is fine for chrome, menus and dialogs.
  Future<void> shot(WidgetTester tester, String name) async {
    final boundary =
        shotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final dir = Directory('build/ui_probe');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/$name.png');
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[ui-probe] screenshot -> ${file.absolute.path}');
    });
  }

  /// Right-click. `tap` with a secondary button is the only way to reach an
  /// `onSecondaryTapUp` handler from a test.
  Future<void> rightClick(WidgetTester tester, Finder finder) async {
    await tester.tap(finder, buttons: kSecondaryButton, warnIfMissed: false);
  }

  /// Boots the real app. Returns once the shell has had time to load.
  Future<void> boot(WidgetTester tester) async {
    // find.bySemanticsLabel needs the semantics tree built, and it is the only
    // way to identify a server icon by name.
    semanticsHandle = tester.ensureSemantics();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shotKey,
        child: const ProviderScope(child: HollowApp()),
      ),
    );
    // Identity unlock, DB open and the first channel load all happen here.
    await settle(tester, frames: 80, step: const Duration(milliseconds: 100));
  }

  /// Selects the server whose tooltip/label matches [name] in the server strip.
  ///
  /// Returns false (rather than failing) when it cannot be found, so the probe
  /// can report a useful message with a screenshot instead of a bare timeout.
  Future<bool> openServer(WidgetTester tester, String name) async {
    // Server icons carry their name as a Semantics label, not a Material
    // Tooltip: the app uses HollowTooltip, which find.byTooltip cannot see.
    // The a11y label is the only text identity a server icon has, since the
    // icon itself is an image or two initials that several servers can share.
    // Match the Semantics WIDGET, not the semantics tree. `bySemanticsLabel`
    // walks merged nodes, and a server icon's label gets absorbed into its
    // parent node, so it finds nothing even though the label is right there.
    final byWidget = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == name);
    for (final finder in [byWidget, find.bySemanticsLabel(name), find.text(name)]) {
      if (finder.evaluate().isEmpty) continue;
      await tester.tap(finder.first, warnIfMissed: false);
      await settle(tester);
      return true;
    }
    return false;
  }

  testWidgets('ui probe: $scenario', (tester) async {
    await boot(tester);
    await shot(tester, '01-boot');

    if (scenario == 'boot') {
      await freezeTickers(tester);
      return;
    }

    final opened = await openServer(tester, serverName);
    await shot(tester, '02-server');
    if (!opened) {
      // Say WHAT was on screen instead of only that the target was not. A
      // probe that cannot find something is only useful if it reports the
      // names it did find.
      final labels = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .map((w) => w.properties.label)
          .whereType<String>()
          .where((l) => l.trim().isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      fail('server "$serverName" not found.\n'
          'See build/ui_probe/02-server.png.\n'
          'Semantics labels present (${labels.length}):\n'
          '${labels.join(" | ")}');
    }

    switch (scenario) {
      case 'channel_menu':
        // Right-click the first channel row in the sidebar.
        final hash = find.byIcon(LucideIcons.hash);
        expect(hash.evaluate(), isNotEmpty,
            reason: 'no text channel rows visible');
        await rightClick(tester, hash.first);
        await settle(tester);
        await shot(tester, '03-channel-menu');

        // Drill into Visibility, which is where the stale-submenu bug lived.
        final visibility = find.text('Visibility');
        if (visibility.evaluate().isNotEmpty) {
          await tester.tap(visibility.first, warnIfMissed: false);
          await settle(tester);
          await shot(tester, '04-visibility-submenu');
        }
        break;

      case 'create_category':
        // Right-click empty sidebar space, well below the channel rows.
        final sidebar = find.byType(Scaffold);
        final box = tester.getRect(sidebar.first);
        final gesture = await tester.startGesture(
          Offset(box.left + 120, box.bottom - 140),
          buttons: kSecondaryButton,
        );
        await gesture.up();
        await settle(tester);
        await shot(tester, '03-sidebar-menu');

        final create = find.text('Create category');
        expect(create.evaluate(), isNotEmpty,
            reason: 'sidebar menu has no "Create category" row — see '
                'build/ui_probe/03-sidebar-menu.png');
        await tester.tap(create.first, warnIfMissed: false);
        await settle(tester);
        await shot(tester, '04-name-dialog');

        // Scope to the DIALOG. The chat composer is a TextField too and comes
        // first in the tree, so `.first` types the category name into the
        // message box and the dialog stays empty.
        final dialogField = find.descendant(
          of: find.byType(HollowDialog),
          matching: find.byType(TextField),
        );
        expect(dialogField.evaluate(), isNotEmpty,
            reason: 'the create-category dialog has no text field - see '
                'build/ui_probe/04-name-dialog.png');
        await tester.enterText(dialogField.first, 'probe-category');
        await settle(tester, frames: 10);
        await tester.tap(
            find.descendant(
                of: find.byType(HollowDialog), matching: find.text('Create')),
            warnIfMissed: false);
        await settle(tester, frames: 40);
        await shot(tester, '05-after-create');

        // The whole point of the scenario: the category must actually appear.
        expect(find.textContaining('PROBE-CATEGORY', findRichText: true)
                .evaluate()
                .isNotEmpty ||
            find.textContaining('probe-category').evaluate().isNotEmpty,
            isTrue,
            reason: 'the new category never appeared in the sidebar — see '
                'build/ui_probe/05-after-create.png');
        break;
    }

    await freezeTickers(tester);
  });
}

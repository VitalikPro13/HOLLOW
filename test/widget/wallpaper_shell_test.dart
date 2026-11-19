// #144 in the real desktop shell: with a wallpaper set, no pane paints the
// opaque canvas, so the DM, channel, Home and split panes show the picture
// under the one dim like Settings does. The shell reads its theme in its own
// build, so the see-through theme has to sit ABOVE the shell.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/identity.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/hollow_shell.dart';

import '../helpers/test_app.dart';

/// A launch with an identity on disk that waits at the unlock: the shell is
/// built behind it, and nothing past it runs.
class _BootApi implements RustLibApi {
  @override
  Future<bool> crateApiStorageHasIdentity() async => true;
  @override
  Future<void> crateApiStorageMarkLinkThrowaway() async {}
  @override
  Future<IdentityInfo> crateApiIdentityUnlockIdentity({String? password}) =>
      Completer<IdentityInfo>().future;
  @override
  Future<bool> crateApiStorageSettleLinkThrowaway() async => false;
  @override
  Future<bool> crateApiStorageHasPendingWipe() async => false;
  @override
  Future<void> crateApiRecoverySettleRelink() async {}
  @override
  Future<void> crateApiIdentitySettleKeychainMove() async {}
  @override
  Future<bool> crateApiStorageHasPendingLink() async => false;
  @override
  Future<String?> crateApiRecoveryRelinkWelcome() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName.toString().contains('crateApi')) {
      return Completer<Never>().future;
    }
    return super.noSuchMethod(invocation);
  }
}

/// No profile registry and no identities on the real disk are read.
final class _NoProfiles extends IOOverrides {
  @override
  File createFile(String path) =>
      path.endsWith('profiles.json') || path.endsWith('identity.key')
          ? _Missing(path)
          : super.createFile(path);
}

class _Missing implements File {
  _Missing(this.path);
  @override
  final String path;
  @override
  bool existsSync() => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// A 1x1 PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
  0x00, 0x05, 0xFE, 0x02, 0xFE, 0xA7, 0x35, 0x81, 0x84, 0x00, 0x00, 0x00,
  0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _Wallpaper extends BackgroundNotifier {
  @override
  BackgroundState build() => BackgroundState(
      imageBytes: _png, panelOpacity: 1.0);
  @override
  Future<void> load() async {}
}

class _NoReduce extends ReduceTransparencyNotifier {
  @override
  Future<bool> build() async => false;
}

final _shellBody = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_ShellScaffold');

void main() {
  setUpAll(() => RustLib.initMock(api: _BootApi()));

  testWidgets('desktop panes over a wallpaper paint no opaque canvas',
      (tester) async {
    if (Platform.isAndroid || Platform.isIOS) return;
    IOOverrides.global = _NoProfiles();
    addTearDown(() => IOOverrides.global = null);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opaqueCanvas = HollowThemeData.dark()
        .extension<HollowTheme>()!
        .opaqueBackground;

    // Disposed after the tree: the shell's own dispose still writes to it.
    final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        backgroundProvider.overrideWith(_Wallpaper.new),
        reduceTransparencyProvider.overrideWith(_NoReduce.new),
      ]),
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        // As app.dart.
        home: const HollowHome(),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(_shellBody, findsOneWidget, reason: 'the desktop shell is up');
    expect(HollowTheme.of(tester.element(find.byType(HollowShell))).background.a,
        0,
        reason: "the shell's own build reads the see-through theme");
    final solid = [
      for (final w in tester.widgetList(find.descendant(
          of: _shellBody,
          matching: find.byWidgetPredicate((w) =>
              (w is Container && w.color == opaqueCanvas) ||
              (w is ColoredBox && w.color == opaqueCanvas)))))
        w.runtimeType,
    ];
    expect(solid, isEmpty,
        reason: 'a pane painting the opaque canvas hides the wallpaper');
    // Outlive the launch's timers.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
    container.dispose();
  });
}

// A fresh install meets Welcome alone: no shell is built behind it before an
// identity exists, and a tablet gets the full-screen first run a phone gets
// (the iPad showed a dialog over "Message store is not open", 0.14 store
// shots).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/rust/api/identity.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/dialogs/welcome_frame.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/hollow_shell.dart';

import '../helpers/test_app.dart';

class _BootApi implements RustLibApi {
  bool identityOnDisk = false;

  /// Set to hold the launch at the identity check (a slow pending import).
  Completer<bool>? identityCheck;

  @override
  Future<bool> crateApiStorageHasIdentity() async =>
      identityCheck == null ? identityOnDisk : identityCheck!.future;

  @override
  Future<void> crateApiStorageMarkLinkThrowaway() async {}

  // An existing identity holds here, the shell already up behind the unlock;
  // a first launch has nothing to unlock and load() makes the identity.
  @override
  Future<IdentityInfo> crateApiIdentityUnlockIdentity({String? password}) =>
      identityOnDisk
          ? Completer<IdentityInfo>().future
          : Future.error(StateError('no identity'));

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

  // Anything else the launch asks waits forever: nothing past Welcome runs.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName.toString().contains('crateApi')) {
      return Completer<Never>().future;
    }
    return super.noSuchMethod(invocation);
  }
}

/// No profile registry and no identities, so no real profile is read.
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

class _NoIdentityYet extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState();

  @override
  Future<void> load() async =>
      state = const IdentityState(peerId: 'fresh', isLoaded: true);
}

final _shellBody = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_ShellScaffold');

/// Launches on [platform] at [size], runs [check], and puts the platform back
/// before the test ends (the binding checks that before any tear-down).
Future<void> _launch(WidgetTester tester, Size size, TargetPlatform platform,
    FutureOr<void> Function() check,
    {double uiScale = 1, double text = 1, Size? display}) async {
  IOOverrides.global = _NoProfiles();
  addTearDown(() => IOOverrides.global = null);
  debugDefaultTargetPlatformOverride = platform;
  try {
    await _pumpShell(tester, size, uiScale, text, display ?? size);
    await check();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// [display] is the whole screen; [size] the app's window on it.
Future<void> _pumpShell(WidgetTester tester, Size size, double uiScale,
    double text, Size display) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.display.size = display;
  tester.view.display.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.display.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      identityProvider.overrideWith(_NoIdentityYet.new),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      // As app.dart: the interface scale shrinks the slot every page sees.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(text)),
        child: UiScaleBox(scale: uiScale, child: child!),
      ),
      home: const HollowShell(),
    ),
  ));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The surface Welcome is drawn on: its nearest Material.
Size _welcomeSurface(WidgetTester tester) => tester.getSize(find
    .ancestor(of: find.text('Welcome to Hollow'), matching: find.byType(Material))
    .first);

void _expectNoShell() {
  expect(_shellBody, findsNothing, reason: 'no shell before an identity');
  expect(find.byType(MobileShell), findsNothing,
      reason: 'no shell before an identity');
  expect(find.textContaining("didn't load"), findsNothing);
  expect(find.textContaining('Good '), findsNothing,
      reason: 'no greeting for an identity that does not exist');
}

void main() {
  final api = _BootApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.identityOnDisk = false;
    api.identityCheck = null;
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final (label, size) in [
      ('portrait', const Size(1032, 1376)),
      ('landscape', const Size(1376, 1032)),
    ]) {
      testWidgets('a fresh ${platform.name} tablet ($label) gets the '
          'full-screen first run and no shell', (tester) async {
        await _launch(tester, size, platform, () {
          expect(find.text('Welcome to Hollow'), findsOneWidget);
          _expectNoShell();
          expect(find.byType(HollowDialogSurface), findsNothing,
              reason: 'Welcome is the screen, not a dialog over one');
          expect(_welcomeSurface(tester), size);
          // One centred column, not a phone's layout stretched to the edges.
          final agree = tester.getRect(find.text('Agree and continue'));
          expect(agree.center.dx, closeTo(size.width / 2, 1));
          expect(
              tester
                  .getSize(find.ancestor(
                      of: find.text('Agree and continue'),
                      matching: find.byType(HollowButton)))
                  .width,
              lessThanOrEqualTo(WelcomeFrame.width));
          // A tablet is not a phone.
          expect(find.textContaining('this phone'), findsNothing);
          expect(find.textContaining('made on this device'), findsOneWidget);
        });
      });
    }
  }

  // Tablets get an automatic interface scale up to 1.5 before any identity
  // exists: the 13in iPad's slot is then 688 wide, an 11in's 549 (phone width).
  for (final (label, size, scale) in [
    ('13in iPad', const Size(1032, 1376), 1.48),
    ('11in iPad', const Size(820, 1180), 1.5),
    ('iPad mini', const Size(744, 1133), 1.5),
  ]) {
    testWidgets('a fresh $label at interface scale $scale keeps the full-screen '
        'first run', (tester) async {
      await _launch(tester, size, TargetPlatform.iOS, () {
        expect(find.text('Welcome to Hollow'), findsOneWidget);
        _expectNoShell();
        expect(find.byType(HollowDialogSurface), findsNothing);
        final slot = size / scale;
        expect(_welcomeSurface(tester).width, closeTo(slot.width, 0.5));
        expect(_welcomeSurface(tester).height, closeTo(slot.height, 0.5));
        expect(tester.takeException(), isNull, reason: 'nothing overflows');
        // The device in hand decides the word, not the scaled slot.
        expect(find.textContaining('made on this device'), findsOneWidget);
      }, uiScale: scale);
    });
  }

  testWidgets('a phone turned on its side keeps the full-screen first run',
      (tester) async {
    const size = Size(844, 390);
    await _launch(tester, size, TargetPlatform.iOS, () {
      _expectNoShell();
      expect(find.byType(HollowDialogSurface), findsNothing);
      expect(_welcomeSurface(tester), size);
      expect(find.textContaining('made on this phone'), findsOneWidget);
    });
  });

  testWidgets('a phone in portrait keeps its first run as it was',
      (tester) async {
    const size = Size(390, 844);
    await _launch(tester, size, TargetPlatform.iOS, () {
      _expectNoShell();
      expect(_welcomeSurface(tester), size);
      expect(find.textContaining('made on this phone'), findsOneWidget);
    });
  });

  testWidgets('a wide desktop window shows the Welcome card over no shell',
      (tester) async {
    await _launch(tester, const Size(1440, 900), TargetPlatform.macOS, () {
      expect(find.text('Welcome to Hollow'), findsOneWidget);
      _expectNoShell();
      expect(find.byType(HollowDialogSurface), findsOneWidget,
          reason: 'the desktop keeps its Welcome card');
    });
  });

  // A phone width, so the host draws MobileShell (the desktop layout's dock
  // claim writes a provider while the test scope tears down).
  testWidgets('the shell opens once Welcome made the identity',
      (tester) async {
    await _launch(tester, const Size(390, 844), TargetPlatform.iOS, () async {
      await tester.tap(find.text('Agree and continue'));
      await tester.pump(const Duration(milliseconds: 300));
      _expectNoShell();
      await tester.tap(find.text('Create an identity'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Welcome to Hollow'), findsNothing);
      expect(find.byType(MobileShell), findsOneWidget);
    });
  });

  testWidgets('an identity on disk builds the shell as before', (tester) async {
    api.identityOnDisk = true;
    await _launch(tester, const Size(390, 844), TargetPlatform.iOS, () {
      expect(find.text('Welcome to Hollow'), findsNothing);
      expect(find.byType(MobileShell), findsOneWidget,
          reason: 'the shell stands behind the unlock, as it always has');
    });
  });

  // The first-run link makes a throwaway identity that every way out of the
  // link relaunches away: no shell is ever built for it.
  for (final (label, size) in [
    ('tablet', const Size(1032, 1376)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('a fresh $label choosing Link a device never shows a shell',
        (tester) async {
      await _launch(tester, size, TargetPlatform.iOS, () async {
        await tester.tap(find.text('Agree and continue'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Link a device').first);
        for (var i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          _expectNoShell();
        }
        expect(find.text('Welcome to Hollow'), findsNothing);
        expect(find.byType(HollowSpinner), findsNothing,
            reason: 'the link steps hold the screen, no spinner waits behind');
      });
    });
  }

  testWidgets('a tablet app in a phone-sized split-screen window still says '
      'this device', (tester) async {
    await _launch(tester, const Size(400, 800), TargetPlatform.android, () {
      expect(find.textContaining('made on this device'), findsOneWidget);
    }, display: const Size(1280, 800));
  });

  // Phone width with the largest text and the relay field open: the actions
  // scroll with the body instead of overflowing (the 11in iPad and the mini
  // reach phone width at the automatic 1.5 scale).
  for (final (label, size, scale) in [
    ('iPad mini at 1.5', const Size(744, 1133), 1.5),
    ('11in iPad at 1.5', const Size(834, 1194), 1.5),
    ('phone', const Size(390, 844), 1.0),
  ]) {
    testWidgets('$label at text scale 2.0 with the relay open does not '
        'overflow', (tester) async {
      await _launch(tester, size, TargetPlatform.iOS, () async {
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Agree and continue'));
        await tester.pump();
        await tester.tap(find.text('Agree and continue'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.ensureVisible(find.text('relay.anonlisten.com').first);
        await tester.pump();
        await tester.tap(find.text('relay.anonlisten.com').first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Relay address'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'no overflow');
      }, uiScale: scale, text: 2.0);
    });
  }

  testWidgets('the actions stay at the foot of the screen when they fit',
      (tester) async {
    const size = Size(390, 844);
    await _launch(tester, size, TargetPlatform.iOS, () async {
      final agree = tester.getRect(find.text('Agree and continue'));
      expect(agree.bottom, greaterThan(size.height * 0.8));
    });
  });

  testWidgets('a slow launch shows a spinner on the bare canvas, never a shell',
      (tester) async {
    api.identityCheck = Completer<bool>();
    await _launch(tester, const Size(1032, 1376), TargetPlatform.iOS, () async {
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(HollowSpinner), findsOneWidget);
      _expectNoShell();
      api.identityCheck!.complete(false);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Welcome to Hollow'), findsOneWidget);
      expect(find.byType(HollowSpinner), findsNothing,
          reason: 'no spinner waits behind Welcome');
    });
  });
}

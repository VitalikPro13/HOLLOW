import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/services/phrase_restore.dart';
import 'package:hollow/src/rust/api/identity.dart';
import 'package:hollow/src/rust/api/roster.dart';
import 'package:hollow/src/rust/api/verification.dart' as verification_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/recovery_phrase_dialogs.dart';
import 'package:hollow/src/ui/dialogs/welcome_dialog.dart';
import 'package:hollow/src/ui/dialogs/welcome_phrase_step.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/ui/shell/roster_lock.dart';

import '../helpers/test_app.dart';

/// The phrase restore's surfaces (PHRASE_RESTORE_DESIGN 5): Welcome's row and
/// step, the kept-data dialogs, Home's card and alert, the roster lock.
/// Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/phrase_restore.
final _desktop = TargetPlatformVariant.only(TargetPlatform.macOS);
final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

const _desk = Size(1280, 800);
const _hand = Size(390, 844);

const _phrase = 'abandon ability able about above absent absorb abstract '
    'absurd abuse access accident account accuse achieve acid acoustic '
    'acquire across act action actor actress actual';
const _added = '12D3KooWAddedAddedAddedAddedAddedAddedAdded';
const _newer = '12D3KooWNewerNewerNewerNewerNewerNewerNewer';

class _Api implements RustLibApi {
  RestoreOutcome Function() outcome =
      () => const RestoreOutcome.keptNoneOpens();
  WelcomeRestoreState? mark;
  bool maySetAside = true;

  @override
  Future<RestoreOutcome> crateApiIdentityWelcomeRestore({
    required String phrase,
    required WelcomeRestoreMode mode,
    required bool checkKept,
  }) async =>
      outcome();

  @override
  Future<WelcomeRestoreState?> crateApiRosterWelcomeRestoreState() async => mark;

  @override
  Future<bool> crateApiIdentityMaySetAsideThisIdentity() async => maySetAside;

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async => null;

  bool setAsideRefused = false;

  @override
  Future<void> crateApiIdentitySetAsideThisIdentity() async {
    if (!setAsideRefused) return;
    maySetAside = false;
    throw 'set aside refused';
  }

  @override
  Future<RosterStatus> crateApiRosterRosterStatus() async => const RosterStatus(
        member: false,
        protected: true,
        backupWait: true,
        tooEarly: 'recover',
        devices: [
          RosterDevice(
              devicePeerId: 'self', state: 'member', thisDevice: true, added: []),
          RosterDevice(
              devicePeerId: _newer, state: 'member', thisDevice: false, added: []),
          RosterDevice(
              devicePeerId: _added, state: 'member', thisDevice: false, added: []),
        ],
      );

  @override
  Future<List<String>> crateApiRosterRecoveryKeptByDefault(
          {required int lostSinceMs}) async =>
      const [_newer];

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Friends extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => const {};
}

class _Alerts extends SecurityAlertsNotifier {
  @override
  List<verification_api.SecurityAlertFfi> build() => const [
        verification_api.SecurityAlertFfi(
          alertId: 'own_device_added:me:$_added:phrase',
          peerId: 'me',
          kind: SecurityAlertKind.ownDeviceAdded,
          detail: '$_added:$kAddedByPhrase',
          createdAt: 0,
        ),
      ];
}

class _Kinds extends DeviceKindNotifier {
  @override
  Map<String, String> build() => const {_added: 'phone', _newer: 'desktop'};
}

class _Gate extends RosterGateNotifier {
  final RosterGate gate;
  _Gate(this.gate);
  @override
  RosterGate build() => gate;
}

final _api = _Api();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}phrase_restore';

  setUpAll(() async {
    RustLib.initMock(api: _api);
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
              ? 'GeistMono'
              : null;
      if (family == null) continue;
      families
          .putIfAbsent(family, () => [])
          .add(ByteData.view(File(face.path).readAsBytesSync().buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });
  setUp(() {
    _api
      ..outcome = (() => const RestoreOutcome.keptNoneOpens())
      ..mark = null
      ..maySetAside = true
      ..setAsideRefused = false;
    keptMatchOffersSwitch = () => true;
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
    });
  }

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;

  Future<void> pumpHost(WidgetTester tester,
      {required Size size,
      bool light = false,
      Widget? home,
      List<Override> extra = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: extra),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: home is MobileShell
              ? home
              : Scaffold(
                  body: Builder(builder: (context) {
                    host = context;
                    return home ?? const SizedBox.expand();
                  }),
                ),
        ),
      ),
    ));
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f.first);
    await tester.tap(f.first, warnIfMissed: false);
    await settle(tester, rounds: 4);
  }

  Future<void> openWelcome(WidgetTester tester,
      {Size size = _desk, bool light = false, bool step = false}) async {
    await pumpHost(tester, size: size, light: light);
    unawaited(showWelcomeDialog(host));
    await settle(tester);
    await tap(tester, find.text('Agree and continue'));
    if (step) await tap(tester, find.text('Use your recovery phrase'));
  }

  Future<void> typeWords(WidgetTester tester) async {
    await tester.enterText(
        find.descendant(
            of: find.byKey(const ValueKey('welcome-phrase-field')),
            matching: find.byType(EditableText)),
        _phrase);
    await settle(tester, rounds: 2);
  }

  // ------------------------------------------------------------- Welcome

  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    testWidgets('welcome first run, desktop $theme', (t) async {
      await openWelcome(t, light: light);
      await capture(t, 'welcome_firstrun_desktop_$theme');
    }, variant: _desktop);

    testWidgets('welcome first run, phone $theme', (t) async {
      await openWelcome(t, size: _hand, light: light);
      await capture(t, 'welcome_firstrun_phone_$theme');
    }, variant: _phone);

    testWidgets('phrase step, desktop $theme', (t) async {
      await openWelcome(t, light: light, step: true);
      await capture(t, 'phrase_step_empty_desktop_$theme');
      await tap(t, find.byKey(const ValueKey('phrase-branch-recover')));
      await tap(t, find.text('In the last 7 days'));
      await typeWords(t);
      await capture(t, 'phrase_step_yes_desktop_$theme');
    }, variant: _desktop);

    testWidgets('phrase step, phone $theme', (t) async {
      await openWelcome(t, size: _hand, light: light, step: true);
      await capture(t, 'phrase_step_empty_phone_$theme');
      await tap(t, find.byKey(const ValueKey('phrase-branch-admit')));
      await typeWords(t);
      await capture(t, 'phrase_step_no_phone_$theme');
    }, variant: _phone);
  }

  testWidgets('phrase step, small phone at text scale 2', (t) async {
    await openWelcome(t, size: const Size(375, 667), step: true);
    t.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await tap(t, find.byKey(const ValueKey('phrase-branch-recover')));
    // The grown row would end at the viewport's foot: bring it to the top.
    await t.ensureVisible(find.byKey(const ValueKey('phrase-branch-recover')));
    await settle(t);
    await capture(t, 'phrase_step_yes_phone375_text2_dark');
  }, variant: _phone);

  testWidgets('phrase step, a wrong word', (t) async {
    _api.outcome = () => throw 'phrase_word:7';
    await openWelcome(t, step: true);
    await tap(t, find.byKey(const ValueKey('phrase-branch-admit')));
    await typeWords(t);
    await tap(t, find.text('Restore'));
    await capture(t, 'phrase_step_error_desktop_dark');
  }, variant: _desktop);

  for (final (size, platform, light) in [
    (_desk, _desktop, false),
    (_desk, _desktop, true),
    (_hand, _phone, false),
    (_hand, _phone, true),
  ]) {
    final where = size == _desk ? 'desktop' : 'phone';
    final theme = light ? 'light' : 'dark';
    testWidgets('phrase step after a set-aside on its own relay, $where $theme',
        (t) async {
      await pumpHost(t, size: size, light: light);
      unawaited(showWelcomeDialog(host,
          afterSetAside: true, relayDomain: 'relay.example.org'));
      await settle(t);
      await capture(t, 'phrase_step_set_aside_relay_${where}_$theme');
    }, variant: platform);
  }

  testWidgets('phrase step after a set-aside', (t) async {
    await pumpHost(t, size: _desk, light: true);
    unawaited(showWelcomeDialog(host, afterSetAside: true));
    await settle(t);
    await capture(t, 'phrase_step_after_set_aside_desktop_light');
  }, variant: _desktop);

  for (final (label, outcome) in [
    (
      'match',
      () => const RestoreOutcome.keptMatch(
          path: '/Users/ada/Library/Application Support/hollow-old-2026-11-02'),
    ),
    ('none_opens', () => const RestoreOutcome.keptNoneOpens()),
  ]) {
    testWidgets('kept data $label, desktop', (t) async {
      _api.outcome = outcome;
      await openWelcome(t, step: true);
      await tap(t, find.byKey(const ValueKey('phrase-branch-admit')));
      await typeWords(t);
      await tap(t, find.text('Restore'));
      await capture(t, 'kept_${label}_desktop_dark');
    }, variant: _desktop);

    // A phone has no profile to switch to: a match restores at once there.
    if (label == 'match') continue;
    testWidgets('kept data $label, phone light', (t) async {
      _api.outcome = outcome;
      await openWelcome(t, size: _hand, light: true, step: true);
      await tap(t, find.byKey(const ValueKey('phrase-branch-admit')));
      await typeWords(t);
      await tap(t, find.text('Restore'));
      await capture(t, 'kept_${label}_phone_light');
    }, variant: _phone);
  }

  // ---------------------------------------------------------------- Home

  List<Override> homeOverrides() => [
        friendsProvider.overrideWith(_Friends.new),
        keptServersProvider.overrideWithValue(const <String, ServerInfo>{}),
        securityAlertsProvider.overrideWith(_Alerts.new),
        deviceKindProvider.overrideWith(_Kinds.new),
      ];

  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    testWidgets('home card No and phrase alert, desktop $theme', (t) async {
      _api.mark = WelcomeRestoreState(
          atMs: DateTime.now().millisecondsSinceEpoch,
          branch: 'admit',
          empty: true,
          noWait: false);
      await pumpHost(t,
          size: _desk,
          light: light,
          home: const HomeDashboard(),
          extra: homeOverrides());
      await capture(t, 'home_card_no_desktop_$theme');
    }, variant: _desktop);

    testWidgets('home card Yes, phone $theme', (t) async {
      _api.mark = WelcomeRestoreState(
          atMs: DateTime.now().millisecondsSinceEpoch,
          branch: 'recover',
          empty: true,
          noWait: true);
      await pumpHost(t,
          size: _hand,
          light: light,
          home: const MobileShell(),
          extra: [
            ...homeOverrides(),
            connectionStatusProvider.overrideWith(TestRelayStatus.new),
          ]);
      await capture(t, 'home_card_yes_phone_$theme');
    }, variant: _phone);
  }

  testWidgets('home card without the retry, desktop wide', (t) async {
    _api
      ..mark = WelcomeRestoreState(
          atMs: DateTime.now().millisecondsSinceEpoch,
          branch: 'recover',
          empty: true,
          noWait: false)
      ..maySetAside = false;
    await pumpHost(t,
        size: const Size(2500, 1000),
        home: const HomeDashboard(),
        extra: homeOverrides());
    await capture(t, 'home_card_yes_noretry_desktop2500_dark');
  }, variant: _desktop);

  testWidgets('set-aside dialog', (t) async {
    _api.mark = WelcomeRestoreState(
        atMs: DateTime.now().millisecondsSinceEpoch,
        branch: 'admit',
        empty: true,
        noWait: false);
    await pumpHost(t,
        size: _desk, home: const HomeDashboard(), extra: homeOverrides());
    await tap(t, find.text('Type my phrase again'));
    await capture(t, 'set_aside_dialog_desktop_dark');
  }, variant: _desktop);

  testWidgets('set-aside refused', (t) async {
    _api
      ..mark = WelcomeRestoreState(
          atMs: DateTime.now().millisecondsSinceEpoch,
          branch: 'admit',
          empty: true,
          noWait: false)
      ..setAsideRefused = true;
    await pumpHost(t,
        size: _desk, home: const HomeDashboard(), extra: homeOverrides());
    await tap(t, find.text('Type my phrase again'));
    await tap(t, find.text('Set aside'));
    await capture(t, 'set_aside_refused_desktop_dark');
  }, variant: _desktop);

  // ---------------------------------------------------------- Roster lock

  for (final (label, gate) in [
    (
      'too_early',
      const RosterGate(
          kind: RosterGateKind.tooEarly, tooEarly: PhraseRestoreBranch.admit),
    ),
    (
      'dropped',
      RosterGate(
          kind: RosterGateKind.pending, droppedAt: DateTime(2026, 11, 20, 14, 5)),
    ),
  ]) {
    for (final light in [false, true]) {
      final theme = light ? 'light' : 'dark';
      testWidgets('roster lock $label, desktop $theme', (t) async {
        await pumpHost(t,
            size: _desk,
            light: light,
            home: const RosterLockScreen(),
            extra: [rosterGateProvider.overrideWith(() => _Gate(gate))]);
        await capture(t, 'lock_${label}_desktop_$theme');
      }, variant: _desktop);
    }
    for (final light in [false, true]) {
      final theme = light ? 'light' : 'dark';
      testWidgets('roster lock $label, phone $theme', (t) async {
        await pumpHost(t,
            size: _hand,
            light: light,
            home: const RosterLockScreen(),
            extra: [rosterGateProvider.overrideWith(() => _Gate(gate))]);
        await capture(t, 'lock_${label}_phone_$theme');
      }, variant: _phone);
    }
  }

  for (final (stored, label) in [
    (DateTime(2026, 11, 19, 9, 30).millisecondsSinceEpoch, 'stored'),
    (null, 'asked'),
  ]) {
    for (final (size, platform, light) in [
      (_desk, _desktop, false),
      (_desk, _desktop, true),
      (_hand, _phone, false),
      (_hand, _phone, true),
    ]) {
      final where = size == _desk ? 'desktop' : 'phone';
      final theme = light ? 'light' : 'dark';
      testWidgets('recover again, moment $label, $where $theme', (t) async {
        await pumpHost(t,
            size: size,
            light: light,
            home: const RosterLockScreen(),
            extra: [
              rosterGateProvider.overrideWith(() => _Gate(RosterGate(
                  kind: RosterGateKind.tooEarly,
                  tooEarly: PhraseRestoreBranch.recover,
                  lostSinceMs: stored))),
              deviceKindProvider.overrideWith(_Kinds.new),
            ]);
        await tap(t, find.text('Use recovery phrase'));
        await capture(t, 'recover_again_${label}_${where}_$theme');
      }, variant: platform);
    }
  }

  // ------------------------------------------------------- Phrase field

  testWidgets('the phrase field hint', (t) async {
    await pumpHost(t, size: _desk);
    unawaited(showCheckPhraseDialog(host));
    await settle(t);
    await capture(t, 'phrase_field_hint_desktop_dark');
  }, variant: _desktop);

}

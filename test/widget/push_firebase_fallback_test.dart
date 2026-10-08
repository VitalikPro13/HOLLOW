/// AR-33, as Vitalik settled it: the service the person picked is sticky and
/// only they change it. While it is broken (a refused registration, an
/// endpoint without Web Push keys, a network error, a distributor uninstalled
/// or turned off) Google covers only with "Fall back to Google" on; off, the
/// relay keeps no Google token. The app retries on start, on return to the
/// screen, on a network change and on a backoff timer, saves a re-listed
/// distributor back to the connector, and returns to the pick by itself. Home
/// shows one item once an outage outlasts the grace, gone again on heal.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/services/relay_triggers.dart';
import 'package:hollow/src/core/services/unified_push_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/notification_settings_section.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/shell/home_inbox.dart';
import 'package:unifiedpush/unifiedpush.dart' show PushEndpoint, PushMessage;

import '../helpers/test_app.dart';

/// Saved settings in memory, and the relay token calls counted.
class _Api implements RustLibApi {
  final settings = <String, String>{};
  final tokens = <String>[];
  int unregisters = 0;

  /// A settings store that cannot be read.
  bool unreadable = false;

  void reset() {
    settings.clear();
    tokens.clear();
    unregisters = 0;
    unreadable = false;
  }

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async {
    if (unreadable) throw StateError('locked');
    return settings[key];
  }

  @override
  Future<void> crateApiNetworkRegisterPushToken(
      {required String token, required String platform}) async {
    tokens.add(platform);
  }

  @override
  Future<void> crateApiNetworkUnregisterPushToken() async {
    unregisters++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _ntfy = 'io.heckel.ntfy';

/// The UnifiedPush connector: the distributor it saved and the installed ones.
class _Connector extends UnifiedPushConnector {
  String? distributor;
  List<String> installed;
  int registers = 0;
  _Connector({this.distributor, this.installed = const [_ntfy]});

  @override
  Future<void> initialize({
    required void Function(PushEndpoint, String) onNewEndpoint,
    required void Function(FailedReason, String) onRegistrationFailed,
    required void Function(String) onUnregistered,
    required void Function(PushMessage, String) onMessage,
  }) async {}

  @override
  Future<String?> getDistributor() async => distributor;

  @override
  Future<List<String>> getDistributors() async => installed;

  @override
  Future<void> saveDistributor(String distributor) async =>
      this.distributor = distributor;

  @override
  Future<void> register() async => registers++;

  @override
  Future<void> unregister() async => distributor = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.reset();
    UnifiedPushController.supportedForTest = true;
  });
  tearDown(() => UnifiedPushController.supportedForTest = null);

  /// A controller started with ntfy picked and working, Google's
  /// re-registration counted.
  Future<(UnifiedPushController, _Connector)> started(List<int> fallbacks,
      {bool fallbackOn = true}) async {
    if (!fallbackOn) api.settings[kFirebaseFallbackSetting] = '0';
    api.settings[kChosenDistributorSetting] = _ntfy;
    final connector = _Connector(distributor: _ntfy);
    final c = UnifiedPushController.forTest(connector: connector)
      ..onFallBackToFirebase = () => fallbacks.add(1);
    await c.init();
    return (c, connector);
  }

  /// The ways a picked service breaks.
  final breaks =
      <String, Future<void> Function(UnifiedPushController, _Connector)>{
    'a refused registration': (c, _) =>
        c.registrationFailedForTest(FailedReason.internalError),
    'a network error': (c, _) =>
        c.registrationFailedForTest(FailedReason.network),
    'an endpoint without Web Push keys': (c, _) =>
        c.newEndpointForTest(PushEndpoint('https://ntfy.example/up', null)),
    'the distributor uninstalled or turned off': (c, conn) {
      conn
        ..distributor = null
        ..installed = const [];
      return c.unregisteredForTest();
    },
  };

  group('the pick is sticky', () {
    for (final way in breaks.entries) {
      for (final on in [true, false]) {
        test('${way.key} keeps ntfy with the fallback ${on ? 'on' : 'off'}',
            () async {
          final fallbacks = <int>[];
          final (c, conn) = await started(fallbacks, fallbackOn: on);

          await way.value(c, conn);

          expect(c.status.value.phase, UnifiedPushPhase.failed);
          expect(c.status.value.distributor, _ntfy);
          expect(api.settings[kChosenDistributorSetting], _ntfy);
          if (on) {
            expect(fallbacks, hasLength(1), reason: 'Google covers');
            expect(c.isActive, isFalse);
          } else {
            expect(fallbacks, isEmpty);
            expect(c.isActive, isTrue,
                reason: 'a later Google token must not reach the relay');
            expect(api.unregisters, 1,
                reason: 'the relay drops a token this run did not send');
            expect(api.tokens, isEmpty);
          }
        });
      }
    }

    test('a start with the distributor gone keeps it, Google off', () async {
      api.settings[kFirebaseFallbackSetting] = '0';
      api.settings[kChosenDistributorSetting] = _ntfy;
      final conn = _Connector(installed: const []);
      final c = UnifiedPushController.forTest(connector: conn);

      await c.init();

      expect(c.status.value.phase, UnifiedPushPhase.failed);
      expect(c.status.value.distributor, _ntfy);
      expect(api.unregisters, 1);
      expect(conn.registers, 0);
    });

    test('with the fallback off an endpoint sent this run stays', () async {
      final (c, _) = await started([], fallbackOn: false);
      c.endpointForTest();
      expect(api.tokens, ['unifiedpush']);

      await c.registrationFailedForTest(FailedReason.network);

      expect(api.unregisters, 0);
    });

    test('a repeated report of one outage acts once', () async {
      final (c, _) = await started([], fallbackOn: false);
      await c.registrationFailedForTest(FailedReason.network);
      await c.registrationFailedForTest(FailedReason.internalError);
      await c.unregisteredForTest();
      expect(api.unregisters, 1);
    });

    test('only the person picks Google, and only they pick again', () async {
      final (c, _) = await started([]);
      await c.registrationFailedForTest(FailedReason.network);

      await c.useFirebase();
      expect(c.status.value.phase, UnifiedPushPhase.off);
      expect(api.settings[kChosenDistributorSetting], '');

      await c.use(_ntfy);
      expect(c.status.value.distributor, _ntfy);
      expect(api.settings[kChosenDistributorSetting], _ntfy);
    });

    test('an install from before learns the pick at its next start',
        () async {
      final conn = _Connector(distributor: _ntfy);
      await UnifiedPushController.forTest(connector: conn).init();
      expect(api.settings[kChosenDistributorSetting], _ntfy);
      expect(conn.registers, 1);
    });
  });

  group('it heals by itself', () {
    test('Google covers, then the pick takes the relay back', () async {
      final fallbacks = <int>[];
      final (c, _) = await started(fallbacks);
      await c.registrationFailedForTest(FailedReason.network);
      expect(fallbacks, hasLength(1));

      c.endpointForTest();

      expect(c.status.value.phase, UnifiedPushPhase.active);
      expect(c.status.value.distributor, _ntfy);
      expect(c.isActive, isTrue);
      expect(api.tokens, ['unifiedpush']);
    });

    final triggers = <String, void Function(UnifiedPushController)>{
      'a network change': (c) => c.networkChangedForTest(),
      'a return to the screen': (c) =>
          c.didChangeAppLifecycleState(AppLifecycleState.resumed),
    };
    for (final t in triggers.entries) {
      test('${t.key} registers the broken pick again', () async {
        final (c, conn) = await started([]);
        await c.registrationFailedForTest(FailedReason.network);
        final before = conn.registers;

        t.value(c);
        await pumpEventQueue();

        expect(conn.registers, before + 1);
      });
    }

    testWidgets('a native network change reaches the retry', (tester) async {
      late UnifiedPushController c;
      late _Connector conn;
      await tester.runAsync(() async {
        (c, conn) = await started([]);
      });
      await c.registrationFailedForTest(FailedReason.network);
      final triggers = RelayTriggers(
        phone: true,
        nudge: (_) {},
        setBackground: (_) {},
        suspend: () async {},
        log: (_) {},
      )..start();
      addTearDown(triggers.dispose);
      final before = conn.registers;

      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          RelayTriggers.channelName,
          const StandardMethodCodec()
              .encodeMethodCall(const MethodCall('network')),
          (_) {});
      await tester.pump();

      expect(conn.registers, before + 1);
      c.endpointForTest();
      // Earlier tests' controllers heard the same change; let their waits end.
      await tester.pump(kPushAnswerWait * 2);
    });

    test('a working pick that went away silently is noticed on return',
        () async {
      final (c, conn) = await started([], fallbackOn: false);
      c.endpointForTest();
      conn
        ..distributor = null
        ..installed = const [];

      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(c.status.value.phase, UnifiedPushPhase.failed);
      expect(c.status.value.distributor, _ntfy);
    });

    test('nothing retries while a registration waits for its answer',
        () async {
      final (c, conn) = await started([]);
      expect(c.status.value.phase, UnifiedPushPhase.registering);
      c.networkChangedForTest();
      await pumpEventQueue();
      expect(conn.registers, 1);
    });

    test('nothing retries while the pick works', () async {
      final (c, conn) = await started([]);
      c.endpointForTest();
      final before = conn.registers;
      c.networkChangedForTest();
      c.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(conn.registers, before);
    });

    testWidgets('the backoff timer registers it again', (tester) async {
      late UnifiedPushController c;
      late _Connector conn;
      await tester.runAsync(() async {
        (c, conn) = await started([]);
      });
      await c.registrationFailedForTest(FailedReason.network);
      final before = conn.registers;
      await tester.pump(kPushRetryDelays.first);
      await tester.pump();
      expect(conn.registers, before + 1);
      await tester.pump(kPushRetryDelays[1]);
      await tester.pump();
      expect(conn.registers, before + 2);
      c.endpointForTest();
    });

    test('a re-listed distributor is saved back and registered', () async {
      final (c, conn) = await started([], fallbackOn: false);
      conn
        ..distributor = null
        ..installed = const [];
      await c.unregisteredForTest();
      final before = conn.registers;

      c.networkChangedForTest();
      await pumpEventQueue();
      expect(conn.registers, before, reason: 'still gone');

      conn.installed = const [_ntfy];
      c.networkChangedForTest();
      await pumpEventQueue();
      expect(conn.distributor, _ntfy);
      expect(conn.registers, before + 1);
    });

    test('a start registers the pick', () async {
      final (_, conn) = await started([]);
      expect(conn.registers, 1);
    });
  });

  group('a reinstalled distributor that stays silent', () {
    /// ntfy uninstalled while picked, the fallback off: the outage is on.
    Future<(UnifiedPushController, _Connector)> gone(
        WidgetTester tester) async {
      late UnifiedPushController c;
      late _Connector conn;
      await tester.runAsync(() async {
        (c, conn) = await started([], fallbackOn: false);
      });
      conn
        ..distributor = null
        ..installed = const [];
      await c.unregisteredForTest();
      return (c, conn);
    }

    Future<void> retryNow(WidgetTester tester, UnifiedPushController c) async {
      c.networkChangedForTest();
      await tester.pump();
    }

    testWidgets('shows the hint once a retry registered and nothing came',
        (tester) async {
      final (c, conn) = await gone(tester);
      conn.installed = const [_ntfy];
      await retryNow(tester, c);
      expect(conn.distributor, _ntfy, reason: 'saved back and registered');
      expect(c.status.value.unanswered, isFalse);

      await tester.pump(kPushAnswerWait + const Duration(seconds: 1));
      expect(c.status.value.unanswered, isTrue);
      expect(c.status.value.distributor, _ntfy);

      c.endpointForTest();
      expect(c.status.value.phase, UnifiedPushPhase.active);
      expect(c.status.value.unanswered, isFalse);
      await tester.pump(kPushRetryDelays.last * 2);
    });

    testWidgets('never while it is uninstalled', (tester) async {
      final (c, _) = await gone(tester);
      await retryNow(tester, c);
      await tester.pump(kPushAnswerWait + const Duration(seconds: 1));
      expect(c.status.value.unanswered, isFalse);
      c.endpointForTest();
      await tester.pump(kPushRetryDelays.last * 2);
    });

    testWidgets('never on a first failure before any retry', (tester) async {
      late UnifiedPushController c;
      await tester.runAsync(() async {
        (c, _) = await started([], fallbackOn: false);
      });
      await c.registrationFailedForTest(FailedReason.network);
      await tester.pump(kPushRetryDelays.first - const Duration(seconds: 1));
      expect(c.status.value.unanswered, isFalse);
      c.endpointForTest();
      await tester.pump(kPushRetryDelays.last * 2);
    });

    testWidgets('a refusal inside the wait counts as an answer',
        (tester) async {
      final (c, conn) = await gone(tester);
      conn.installed = const [_ntfy];
      await retryNow(tester, c);
      await c.registrationFailedForTest(FailedReason.network);

      await tester.pump(kPushAnswerWait + const Duration(seconds: 1));

      expect(c.status.value.unanswered, isFalse);
      c.endpointForTest();
      await tester.pump(kPushRetryDelays.last * 2);
    });

    testWidgets('an answer from the distributor takes it away',
        (tester) async {
      final (c, conn) = await gone(tester);
      conn.installed = const [_ntfy];
      await retryNow(tester, c);
      await tester.pump(kPushAnswerWait + const Duration(seconds: 1));
      expect(c.status.value.unanswered, isTrue);

      await c.registrationFailedForTest(FailedReason.network);
      expect(c.status.value.unanswered, isFalse);
      c.endpointForTest();
      await tester.pump(kPushRetryDelays.last * 2);
    });
  });

  group('the Home item', () {
    testWidgets('shows after the grace, not before, and clears on heal',
        (tester) async {
      late UnifiedPushController c;
      await tester.runAsync(() async {
        (c, _) = await started([], fallbackOn: false);
      });
      await c.registrationFailedForTest(FailedReason.network);
      await tester.pump(kPushAttentionGrace - const Duration(seconds: 1));
      expect(c.needsAttention.value, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(c.needsAttention.value, isTrue);

      c.endpointForTest();
      expect(c.needsAttention.value, isFalse);
    });

    testWidgets('a blip healed inside the grace never shows', (tester) async {
      late UnifiedPushController c;
      await tester.runAsync(() async {
        (c, _) = await started([]);
      });
      await c.registrationFailedForTest(FailedReason.network);
      await tester.pump(kPushAttentionGrace - const Duration(seconds: 5));
      c.endpointForTest();
      await tester.pump(kPushAttentionGrace * 2);
      expect(c.needsAttention.value, isFalse);
    });

    Future<void> pumpHome(WidgetTester tester, PushAttention? push) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          homeSetupProvider.overrideWith(_Setup.new),
          pushAttentionProvider.overrideWithValue(push),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(body: HomeAttention()),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('says notifications are off with the fallback off',
        (tester) async {
      await pumpHome(
          tester, (distributor: _ntfy, googleWakes: false, unanswered: false));
      expect(find.text('Notifications are off'), findsOneWidget);
      expect(find.textContaining("ntfy isn't working right now"),
          findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
    });

    testWidgets('says Google covers with the fallback on', (tester) async {
      await pumpHome(
          tester, (distributor: _ntfy, googleWakes: true, unanswered: false));
      expect(find.text('Google is waking this phone'), findsOneWidget);
    });

    testWidgets('asks to open a silent reinstalled distributor once',
        (tester) async {
      await pumpHome(
          tester, (distributor: _ntfy, googleWakes: false, unanswered: true));
      expect(find.text('Notifications are off'), findsOneWidget);
      expect(
          find.text(
              "ntfy isn't answering yet. Open it once and Hollow picks it up."),
          findsOneWidget);
    });

    testWidgets('is absent while nothing is broken', (tester) async {
      await pumpHome(tester, null);
      expect(find.text('Notifications are off'), findsNothing);
      expect(find.text('Google is waking this phone'), findsNothing);
    });
  });

  group('the fallback setting', () {
    test('turning it on while broken covers at once, off withdraws Google',
        () async {
      final fallbacks = <int>[];
      final (c, _) = await started(fallbacks, fallbackOn: false);
      await c.registrationFailedForTest(FailedReason.network);
      expect(api.unregisters, 1);

      await c.setFirebaseFallback(true);
      expect(fallbacks, hasLength(1));
      expect(c.isActive, isFalse);

      await c.setFirebaseFallback(false);
      expect(api.unregisters, 2);
      expect(c.isActive, isTrue);
      expect(c.status.value.distributor, _ntfy);
    });

    test('an unread setting never lets Google cover', () async {
      final fallbacks = <int>[];
      final (c, _) = await started(fallbacks);
      c.firebaseFallback.value = null;
      api.unreadable = true;

      await c.registrationFailedForTest(FailedReason.internalError);

      expect(fallbacks, isEmpty);
      expect(c.isActive, isTrue);
    });

    test('the choice survives a restart and defaults to on', () async {
      expect(await UnifiedPushController.forTest().loadFirebaseFallback(),
          isTrue);
      await UnifiedPushController.forTest().setFirebaseFallback(false);
      expect(await UnifiedPushController.forTest().loadFirebaseFallback(),
          isFalse);
    });
  });

  group('Settings', () {
    final controller = UnifiedPushController.instance;
    setUp(() {
      controller.status.value = UnifiedPushStatus.off;
      controller.firebaseFallback.value = null;
      controller.onFallBackToFirebase = null;
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(
            body: SettingsDensity(
              touch: true,
              child: SingleChildScrollView(child: NotificationSettingsView()),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    Finder toggle() => find.byWidgetPredicate(
        (w) => w is HollowToggle && w.semanticLabel == 'Fall back to Google');

    testWidgets('the row is on by default and saves a change', (tester) async {
      await pump(tester);
      expect(tester.widget<HollowToggle>(toggle()).value, isTrue);
      await tester.tap(toggle());
      await tester.pump();
      await tester.pump();
      expect(api.settings[kFirebaseFallbackSetting], '0');
      expect(tester.widget<HollowToggle>(toggle()).value, isFalse);
    });

    testWidgets('a broken pick stays selected, even when not installed',
        (tester) async {
      api.settings[kFirebaseFallbackSetting] = '0';
      controller.status.value = const UnifiedPushStatus(
          UnifiedPushPhase.failed,
          distributor: _ntfy,
          failure: FailedReason.network);
      await pump(tester);
      final chip = tester.widget<HollowChip>(find.byWidgetPredicate(
          (w) => w is HollowChip && w.label == 'ntfy'));
      expect(chip.selected, isTrue);
      expect(
          find.text("ntfy isn't working right now. "
              "Notifications are off until it's back."),
          findsOneWidget);
    });

    testWidgets('a silent reinstalled pick asks to be opened once',
        (tester) async {
      controller.status.value = const UnifiedPushStatus(
          UnifiedPushPhase.failed,
          distributor: _ntfy,
          failure: FailedReason.internalError,
          unanswered: true);
      await pump(tester);
      expect(
          find.text(
              "ntfy isn't answering yet. Open it once and it starts working."),
          findsOneWidget);
    });

    testWidgets('with the fallback on it says Google covers', (tester) async {
      controller.status.value = const UnifiedPushStatus(
          UnifiedPushPhase.failed,
          distributor: _ntfy,
          failure: FailedReason.network);
      await pump(tester);
      expect(
          find.text("ntfy isn't working right now. "
              "Google wakes the phone until it's back."),
          findsOneWidget);
    });

    testWidgets('never shows where UnifiedPush does not exist',
        (tester) async {
      UnifiedPushController.supportedForTest = false;
      await pump(tester);
      expect(find.text('Fall back to Google'), findsNothing);
      expect(find.text('Push delivery'), findsNothing);
    });
  });
}

class _Setup extends HomeSetupNotifier {
  @override
  HomeSetupState build() =>
      const HomeSetupState(loaded: true, hidden: true, phraseSaved: true);
}

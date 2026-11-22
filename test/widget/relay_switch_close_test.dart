// A relay switch ends the app so the node starts on the new relay, but iOS
// gives an app no sanctioned way to quit: `SystemNavigator.pop` does nothing
// there, so "Switch and close" used to spin forever with the app still open
// on the old relay (session C's iPhone checks, Nov 22). On iOS the switch now
// saves the relay for the next launch, leaves this process on the relay it
// runs on, and says to close Hollow; nothing is hung up or shut down.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/ui/settings/network_section.dart';

const _running = 'hollowtest.duckdns.org';
const _other = 'other.example.org';

// The keys as stored, spelled out: the push fetch reads `relay_domain` from
// Rust (`fetch::RELAY_DOMAIN_KEY`).
const _relayKey = 'relay_domain';
const _nextKey = 'relay_domain_next';

class _Api implements RustLibApi {
  final saved = <String, String>{};
  var shutdowns = 0;

  @override
  Future<void> crateApiStorageSaveSetting({
    required String key,
    required String value,
  }) async {
    saved[key] = value;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      saved[key];

  @override
  Future<void> crateApiNetworkNotifyShutdown() async => shutdowns++;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Relay extends RelayDomainNotifier {
  @override
  String build() => _running;
}

class _Relays extends SavedRelayListNotifier {
  @override
  List<String> build() => const [_running, _other];
}

class _Status extends RelayStatusNotifier {
  @override
  RelayStatus build() => const RelayStatus();
}

class _Stats extends RelayStatsNotifier {
  @override
  RelayStats build() => const RelayStats();
}

class _AlwaysRelay extends AlwaysRelayCallsNotifier {
  @override
  bool build() => false;
}

late BuildContext _ctx;
late WidgetRef _ref;

Future<void> _pump(WidgetTester tester, {Widget? child}) async {
  tester.view.physicalSize = const Size(400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        relayDomainProvider.overrideWith(_Relay.new),
        savedRelayListProvider.overrideWith(_Relays.new),
        relayStatusProvider.overrideWith(_Status.new),
        relayStatsProvider.overrideWith(_Stats.new),
        alwaysRelayCallsProvider.overrideWith(_AlwaysRelay.new),
        overallConnectionProvider.overrideWithValue(OverallConnection.connected),
      ],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            _ctx = context;
            _ref = ref;
            return SingleChildScrollView(child: child ?? const SizedBox());
          }),
        ),
      ),
    ),
  );
  await tester.pump();
}

// RelayLoadBars runs a periodic sweep: unmount it before the test ends.
Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

Iterable<HollowButton> _filled(WidgetTester tester) => tester
    .widgetList<HollowButton>(find.byType(HollowButton))
    .where((b) => b.variant == HollowButtonVariant.filled);

/// Long enough for every bounded step of an exit (the 4 s hang-up cap, the
/// 200 ms shutdown pause) to have run out.
Future<void> _settleExit(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(seconds: 1));
  }
}

void main() {
  final api = _Api();
  final platformCalls = <String>[];
  var hookRuns = 0;

  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.saved
      ..clear()
      ..[_relayKey] = _running;
    api.shutdowns = 0;
    platformCalls.clear();
    hookRuns = 0;
    beforeAppExit = () async => hookRuns++;
    debugRelaySwitchEnd = RelaySwitchEnd.closeByHand;
  });
  tearDown(() {
    beforeAppExit = null;
    debugRelaySwitchEnd = null;
  });

  void watchPlatform(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call.method);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
  }

  /// What the push fetch dials now, and what the next launch runs on.
  void expectRunningRelayKept({String? next}) {
    expect(api.saved[_relayKey], _running,
        reason: 'the push fetch dials this key: it must name the relay this '
            'install runs on, holding its push token and buffers');
    expect(api.saved[_nextKey] ?? '', next ?? '');
  }

  /// A fresh launch: the real notifier loads what was saved.
  Future<String> relaunch() async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(relayDomainProvider.notifier).loadCached();
    return c.read(relayDomainProvider);
  }

  void expectNothingEnded() {
    expect(platformCalls, isNot(contains('SystemNavigator.pop')),
        reason: 'pop does nothing on iOS: the switch must not lean on it');
    expect(hookRuns, 0, reason: 'a call would be hung up in an app that stays');
    expect(api.shutdowns, 0, reason: 'the node keeps running until the close');
  }

  group('iOS', () {
    testWidgets('Settings > Network saves the relay, stops loading and says '
        'to close Hollow', (tester) async {
      watchPlatform(tester);
      await _pump(tester, child: const RelaySettingsSection());
      await tester.tap(find.text('Change'));
      await tester.pump();
      await tester.tap(find.text(_other));
      await tester.pump();

      await tester.tap(find.byWidget(_filled(tester).single));
      await _settleExit(tester);

      expect(_filled(tester).where((b) => b.loading), isEmpty,
          reason: 'the switch button spun forever');
      expect(find.textContaining('Close Hollow from the app switcher'),
          findsOneWidget);
      expectRunningRelayKept(next: _other);
      expect(_ref.read(relayDomainProvider), _running,
          reason: 'this process still runs on the old relay');
      expect(_ref.read(pendingRelayProvider), _other);
      expectNothingEnded();

      // Picking the running relay again takes the switch back.
      await tester.tap(find.text(_running).last);
      await tester.pump();
      await tester.tap(find.byWidget(_filled(tester).single));
      await tester.pump();
      await tester.pump();
      expectRunningRelayKept();
      expect(_ref.read(pendingRelayProvider), isNull);
      expect(find.textContaining('Close Hollow from the app switcher'),
          findsNothing);
      await _unmount(tester);
    });

    testWidgets('removing the relay a switch waits for takes the switch back',
        (tester) async {
      await _pump(tester, child: const RelaySettingsSection());
      await tester.tap(find.text('Change'));
      await tester.pump();
      await tester.tap(find.text(_other));
      await tester.pump();
      await tester.tap(find.byWidget(_filled(tester).single));
      await _settleExit(tester);
      expect(_ref.read(pendingRelayProvider), _other);

      await tester.tap(find.bySemanticsLabel('More for $_other'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from the list'));
      await tester.pumpAndSettle();
      expectRunningRelayKept();
      expect(_ref.read(pendingRelayProvider), isNull);
      expect(find.textContaining('Close Hollow from the app switcher'),
          findsNothing);
      await _unmount(tester);
    });

    testWidgets('an invite on another relay saves the invite and the relay, '
        'then says to close Hollow', (tester) async {
      watchPlatform(tester);
      await _pump(tester);
      final link =
          classifyHollowLink('hollow://join?server=abc123&relay=$_other')!;
      var answered = false;
      unawaited(ensureRelayForInvite(_ctx, _ref, link)
          .then((_) => answered = true));
      await tester.pumpAndSettle();

      await tester.tap(find.byWidget(_filled(tester).single));
      await _settleExit(tester);

      expect(find.text('Close and reopen Hollow'), findsOneWidget);
      expect(find.textContaining('Close Hollow from the app switcher'),
          findsOneWidget);
      expect(_filled(tester).where((b) => b.loading), isEmpty);
      expectRunningRelayKept(next: _other);
      expect(api.saved[kPendingInviteAfterSwitchKey], link.fullUrl);
      expect(_ref.read(relayDomainProvider), _running);
      expectNothingEnded();
      expect(answered, isFalse, reason: 'the dialog is still open');
    });

    testWidgets('an access key prompt that falls back to the default relay '
        'says to close Hollow, and a typed key takes it back', (tester) async {
      watchPlatform(tester);
      await _pump(tester);
      String? key = 'unanswered';
      unawaited(showLicenseKeyDialog(_ctx).then((k) => key = k));
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Use the default relay'));
      await _settleExit(tester);

      expect(find.textContaining('Close Hollow from the app switcher'),
          findsOneWidget);
      expect(find.textContaining('Use the default relay'), findsNothing);
      expectRunningRelayKept(next: kDefaultRelayDomain);
      expect(_ref.read(relayDomainProvider), _running);
      expectNothingEnded();

      await tester.enterText(find.byType(TextField), 'ABCD1234EFGH5678');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(key, 'ABCD-1234-EFGH-5678');
      expectRunningRelayKept();
      expect(_ref.read(pendingRelayProvider), isNull,
          reason: 'a key for this relay keeps the person on it');
    });

    testWidgets('an access key prompt keeps a switch made on another screen '
        'and says what a typed key does', (tester) async {
      await _pump(tester);
      await _ref.read(relayDomainProvider.notifier).saveForNextLaunch(_other);
      String? key = 'unanswered';
      unawaited(showLicenseKeyDialog(_ctx).then((k) => key = k));
      await tester.pumpAndSettle();

      expect(
          find.text('Hollow connects to $_other after you close it from the '
              'app switcher and open it again. A key you enter here is for '
              '$_running, and Hollow stays on $_running until then.'),
          findsOneWidget);
      expect(find.textContaining('Use the default relay'), findsNothing);

      await tester.enterText(find.byType(TextField), 'ABCD1234EFGH5678');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(key, 'ABCD-1234-EFGH-5678');
      expect(_ref.read(pendingRelayProvider), _other,
          reason: 'the prompt took back a switch it did not make');
      expectRunningRelayKept(next: _other);
      expect(await relaunch(), _other);
    });

    testWidgets('the next launch runs on the saved relay and the push fetch '
        'follows it', (tester) async {
      await _pump(tester, child: const RelaySettingsSection());
      await tester.tap(find.text('Change'));
      await tester.pump();
      await tester.tap(find.text(_other));
      await tester.pump();
      await tester.tap(find.byWidget(_filled(tester).single));
      await _settleExit(tester);
      expectRunningRelayKept(next: _other);
      await _unmount(tester);

      expect(await relaunch(), _other);
      expect(api.saved[_relayKey], _other);
      expect(api.saved[_nextKey], '',
          reason: 'a later launch must not take the switch again');
      expect(await relaunch(), _other);
    });

    testWidgets('taking a switch back drops the invite it parked, so no later '
        'launch joins it', (tester) async {
      await _pump(tester, child: const RelaySettingsSection());
      final link =
          classifyHollowLink('hollow://join?server=abc123&relay=$_other')!;
      unawaited(ensureRelayForInvite(_ctx, _ref, link));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch relay'));
      await _settleExit(tester);
      expect(api.saved[kPendingInviteAfterSwitchKey], link.fullUrl);
      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();

      // Settings still has the running relay picked: staying on it takes
      // the switch back.
      await tester.tap(find.text('Stay on this relay'));
      await tester.pump();
      await tester.pump();
      expectRunningRelayKept();
      expect(api.saved[kPendingInviteAfterSwitchKey], '',
          reason: 'a later switch to $_other would join the invite unasked');
      await _unmount(tester);
    });

    testWidgets('every take-back clears the waiting relay', (tester) async {
      await _pump(tester);
      final n = _ref.read(relayDomainProvider.notifier);
      await n.saveForNextLaunch(_other);
      api.saved[kPendingInviteAfterSwitchKey] = 'hollow://join?server=x';
      await n.saveForNextLaunch(_running);
      expectRunningRelayKept();
      expect(api.saved[kPendingInviteAfterSwitchKey], '');
      expect(await relaunch(), _running);
    });
  });

  test('Android ends the process, never only its screen', () {
    // A closed screen keeps the process and a node bound to the old relay:
    // the app opened again said "Node is already running" (Nov 22).
    final src = File('lib/src/core/app_relaunch.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(src, isNot(contains('SystemNavigator.pop(')));
    final at = src.indexOf('Future<Never> exitForRelaySwitch(');
    expect(at, isNot(-1));
    final body = src.substring(at, src.indexOf('\n}\n', at));
    expect(body, contains('return relaunchApp();'));
    expect(src, contains('return exitForRelaySwitch();'));
  });

  test('every switch waits for the next launch, Android and desktop too', () {
    // A process ending on its own still leaves the push fetch a window (a
    // cold Android process) before the next launch: it must dial the relay
    // holding this install's push token, never the new one.
    final src = File('lib/src/core/app_relaunch.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final at = src.indexOf('Future<bool> switchRelay(');
    expect(at, isNot(-1));
    final body = src.substring(at, src.indexOf('\n}\n', at));
    expect(body, isNot(contains('setDomain(')));
    expect(body.indexOf('saveForNextLaunch(domain)'),
        lessThan(body.indexOf('exitForRelaySwitch()')));
  });

  group('copy says what happens', () {
    Future<String> switchBody(WidgetTester tester) async {
      await _pump(tester);
      final link =
          classifyHollowLink('hollow://join?server=abc123&relay=$_other')!;
      unawaited(ensureRelayForInvite(_ctx, _ref, link));
      await tester.pumpAndSettle();
      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((r) => r.text.toPlainText())
          .firstWhere((t) => t.startsWith('It is on'));
      return rich;
    }

    testWidgets('iOS says the switch lands on the next open', (tester) async {
      final body = await switchBody(tester);
      expect(
          body,
          contains('Switching takes effect after you close Hollow from the '
              'app switcher and open it again. Then your servers and friends '
              'on $_running go quiet until you switch back.'));
      expect(body, isNot(contains('restarts')));
      expect(find.text('Switch relay'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());

      await _pump(tester, child: const RelaySettingsSection());
      await tester.tap(find.text('Change'));
      await tester.pump();
      await tester.tap(find.text(_other));
      await tester.pump();
      expect(find.text('Switch relay'), findsOneWidget);
      expect(
          find.text('Hollow connects to the new relay after you close it '
              'from the app switcher and open it again.'),
          findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Android closes', (tester) async {
      debugRelaySwitchEnd = RelaySwitchEnd.close;
      final body = await switchBody(tester);
      expect(body, contains('Switching closes Hollow'));
      expect(body, contains('Open Hollow again to finish joining.'));
      expect(find.text('Switch and close app'), findsOneWidget);
    });

    testWidgets('a desktop restarts', (tester) async {
      debugRelaySwitchEnd = RelaySwitchEnd.restart;
      final body = await switchBody(tester);
      expect(body, contains('Switching restarts Hollow'));
      expect(body, contains('Hollow finishes this join after the restart.'));
      expect(find.text('Switch and restart'), findsOneWidget);
    });

    testWidgets('no copy carries an em dash', (tester) async {
      for (final end in RelaySwitchEnd.values) {
        debugRelaySwitchEnd = end;
        final body = await switchBody(tester);
        expect(body, isNot(contains('—')));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });
}

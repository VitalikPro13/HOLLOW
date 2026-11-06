/// #123: the first-run "Link a device" launch runs on a throwaway identity the
/// next launch wipes, so only a landed link may stay in the process: every
/// other way out goes back to Welcome, and the boot wipe settles the link's
/// mark before it looks for a queued wipe.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/ui/shell/first_run_link.dart';

final _calls = <String>[];

class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkReleaseLinkCode() async {}

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<bool> crateApiStorageSettleLinkThrowaway() async {
    _calls.add('settle');
    return true;
  }

  @override
  Future<bool> crateApiStorageHasPendingWipe() async {
    _calls.add('pending');
    return true;
  }

  @override
  Future<bool> crateApiStoragePerformPendingWipe() async {
    _calls.add('wipe');
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OwnRelay extends RelayDomainNotifier {
  @override
  String build() => 'myrelay.duckdns.org';
}

Future<BuildContext> _pump(WidgetTester tester) async {
  final c = ProviderContainer(overrides: [
    overallConnectionProvider.overrideWithValue(OverallConnection.offline),
    relayDomainProvider.overrideWith(_OwnRelay.new),
  ]);
  addTearDown(c.dispose);
  late BuildContext home;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Builder(builder: (context) {
        home = context;
        return const SizedBox();
      }),
    ),
  ));
  return home;
}

/// Spinners never settle, so routes are given their time.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _placeholder = 'Connecting to link your device…';
final _linkDialog = find.text('Link code');

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));
  setUp(_calls.clear);

  testWidgets('the link dialog waits for the relay key prompt', (tester) async {
    final home = await _pump(tester);
    showConnectingDialog(home, message: _placeholder);
    await _settle(tester);
    final prompt = Completer<void>();
    unawaited(showHollowDialog<void>(
      context: home,
      barrierDismissible: false,
      builder: (_) => const HollowDialog(
        title: 'This relay needs an access key',
        content: SizedBox(),
      ),
    ));
    await _settle(tester);

    var abandoned = false;
    unawaited(runFirstRunLink(
      home,
      startUp: () async => true,
      keyPrompt: () => prompt.future,
      abandon: () async => abandoned = true,
    ));
    await _settle(tester);
    expect(_linkDialog, findsNothing,
        reason: 'the link dialog opened over an unanswered key prompt');
    expect(find.text(_placeholder), findsOneWidget);

    prompt.complete();
    await _settle(tester);
    expect(_linkDialog, findsOneWidget);
    expect(find.text(_placeholder), findsNothing);
    expect(abandoned, isFalse);
  });

  testWidgets('Back goes to Welcome, a system back changes nothing',
      (tester) async {
    final home = await _pump(tester);
    var abandoned = 0;
    unawaited(runFirstRunLink(
      home,
      startUp: () async => true,
      keyPrompt: () => null,
      abandon: () async => abandoned++,
    ));
    await _settle(tester);
    expect(_linkDialog, findsOneWidget);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(_linkDialog, findsOneWidget);
    expect(abandoned, 0);

    await tester.tap(find.bySemanticsLabel(RegExp('Back')).first);
    await _settle(tester);
    expect(_linkDialog, findsNothing);
    expect(abandoned, 1);
  });

  testWidgets('a system back leaves the placeholder and a linking key prompt',
      (tester) async {
    final home = await _pump(tester);
    showConnectingDialog(home, message: _placeholder);
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text(_placeholder), findsOneWidget);

    var answered = false;
    unawaited(showLicenseKeyDialog(home, linking: true)
        .then((_) => answered = true));
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('This relay needs an access key'), findsOneWidget);
    expect(answered, isFalse);
    dismissConnectingDialog();
  });

  testWidgets('outside a link, a system back still closes the key prompt',
      (tester) async {
    final home = await _pump(tester);
    var answered = false;
    unawaited(showLicenseKeyDialog(home).then((_) => answered = true));
    await _settle(tester);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(answered, isTrue);
  });

  testWidgets('a launch that stops short or fails goes to Welcome',
      (tester) async {
    final home = await _pump(tester);
    var abandoned = 0;
    unawaited(runFirstRunLink(
      home,
      startUp: () async => false,
      keyPrompt: () => null,
      abandon: () async => abandoned++,
    ));
    await _settle(tester);
    expect(_linkDialog, findsNothing);
    expect(abandoned, 1, reason: 'an unanswered key prompt went on');

    unawaited(runFirstRunLink(
      home,
      startUp: () async => throw StateError('relay status'),
      keyPrompt: () => null,
      abandon: () async => abandoned++,
    ));
    await _settle(tester);
    expect(_linkDialog, findsNothing);
    expect(abandoned, 2, reason: 'a failed launch went on');
  });

  test('the boot wipe settles a link mark before it looks for a wipe',
      () async {
    await finishBootWipe();
    expect(_calls, ['settle', 'pending', 'wipe']);
  });

  test('the shell links a fresh device only through these guards', () {
    final shell = File('lib/src/ui/shell/hollow_shell.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(shell, contains('Future<void> _finishPendingWipe() => finishBootWipe();'));
    expect(shell, contains('keyPrompt: () => _keyPrompt,'));
    expect(shell, contains('_keyPrompt = prompt.future;'));
    expect(shell, isNot(contains('mode: DeviceLinkMode.enterCode')),
        reason: 'the link dialog opens outside runFirstRunLink');
    expect(
        RegExp(r"identityProvider\.notifier\)\.load\(\);\n(\s*//.*\n)*"
                r"\s*if \(welcomeResult\?\.action == 'link_device'\) \{\n"
                r'\s*await storage_api\.markLinkThrowaway\(\)')
            .hasMatch(shell),
        isTrue,
        reason: 'the throwaway is not marked the moment it exists');

    // A phone screen that only closes keeps the process and the open store.
    final prompt = File('lib/src/ui/dialogs/license_key_dialog.dart')
        .readAsStringSync();
    expect(prompt, contains('exitForRelaySwitch(endProcess: widget.linking)'));
    final exit = File('lib/src/core/app_relaunch.dart').readAsStringSync();
    expect(exit, contains('if (endProcess) await relaunchApp();'));
  });
}

/// A link dialog that goes away takes a code still waiting for the relay with it:
/// nothing else ends that wait, and it keeps the relay session (and an Android
/// phone's keep-alive service) up.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/services/link_keep_alive.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';

class _Api implements RustLibApi {
  int releases = 0;

  @override
  Future<void> crateApiNetworkReleaseLinkCode() async => releases++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));

  testWidgets('a closed link dialog ends a code that waits for the relay', (tester) async {
    final c = ProviderContainer(overrides: [
      overallConnectionProvider.overrideWithValue(OverallConnection.offline),
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

    unawaited(showDeviceLinkDialog(home, mode: DeviceLinkMode.showCode));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.renewingCode);
    expect(c.read(linkPresentingProvider), isTrue);

    // Gone some other way than its Cancel button.
    Navigator.of(home).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.read(deviceLinkSyncProvider).phase, LinkPhase.idle);
    expect(c.read(linkPresentingProvider), isFalse);
    expect(api.releases, 1);
  });
}

/// REVIEW (t14-123): the first-run link dialog must have no exit but Back
/// (stash wipe + relaunch) or a landed link. A system back (Android) that pops it
/// returns null, the shell treats that as "not wentBack" and runs on the marked
/// throwaway, which the next launch then wipes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';

class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkReleaseLinkCode() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  testWidgets('a system back never leaves the first-run link dialog', (tester) async {
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

    bool? wentBack = false;
    var closed = false;
    unawaited(showDeviceLinkDialog(home, mode: DeviceLinkMode.enterCode).then((v) {
      wentBack = v;
      closed = true;
    }));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Link a device'), findsWidgets);

    // Android's back button / predictive back gesture.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(closed && wentBack != true, isFalse,
        reason: 'system back closed the link dialog with $wentBack: the shell '
            'goes on into the app on the throwaway it wipes next launch');
  });
}

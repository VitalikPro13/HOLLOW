// The desktop lock cover.
//
// The whole point of the cover is that nothing underneath it can be reached, so
// that is what this pins: the content beneath stops taking taps, and Escape is
// not a way out.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/download_manager_popup.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/shell/lock_cover.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('the cover takes the taps the content beneath would have',
      (tester) async {
    var taps = 0;
    final navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navKey,
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => taps++,
                child: const Text('Open conversation'),
              ),
            ),
          ),
        ),
      ),
    );

    final spot = tester.getCenter(find.text('Open conversation'));
    await tester.tap(find.text('Open conversation'));
    await tester.pump();
    expect(taps, 1);

    navKey.currentState!.push(lockCoverRoute());
    await tester.pumpAndSettle();

    expect(find.text('Hollow is locked'), findsOneWidget);
    expect(find.text('Open conversation'), findsNothing);

    await tester.tapAt(spot);
    await tester.pump();
    expect(taps, 1, reason: 'the cover must swallow the tap');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Hollow is locked'), findsOneWidget,
        reason: 'Escape is not a way out');
  });

  testWidgets('raising the lock closes an open overlay host', (tester) async {
    late BuildContext ctx;
    late WidgetRef widgetRef;

    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(extra: [
          identityProtectionProvider.overrideWith((ref) async =>
              const identity_api.ProtectionStatus(
                isEncrypted: true,
                hasPassword: true,
                hasOsKeychain: false,
                osKeychainAvailable: true,
              )),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Consumer(builder: (context, ref, _) {
            ctx = context;
            widgetRef = ref;
            return const Scaffold(body: SizedBox.expand());
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The shell keeps this warm for the same reason: a lock decision reads it
    // synchronously and refuses while it is still loading.
    await widgetRef.read(identityProtectionProvider.future);
    await tester.pumpAndSettle();

    // A raw OverlayEntry host, the same kind the pickers use: it registers with
    // OverlayHosts and therefore sits above every route.
    showDownloadManagerPopup(context: ctx, anchor: const Offset(100, 100));
    await tester.pumpAndSettle();
    expect(find.text('Downloads'), findsOneWidget);
    expect(OverlayHosts.openCount, 1);

    requestAppLock(widgetRef, ctx);
    await tester.pumpAndSettle();

    expect(find.text('Downloads'), findsNothing,
        reason: 'a host left open would paint over the cover');
    expect(OverlayHosts.openCount, 0);
    expect(widgetRef.read(appLockedProvider), isTrue);
  });
}

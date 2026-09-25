import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_progress_bar.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';

/// A link flow whose Rust calls fail on demand.
class _Link extends DeviceLinkSyncNotifier {
  _Link(this.seed);

  final DeviceLinkState seed;
  static Object? acceptError;
  static Object? declineError;
  static String? enteredCode;

  @override
  DeviceLinkState build() {
    super.build();
    return seed;
  }

  @override
  Future<void> acceptPush(String targetPeer,
      {required bool includeVault, required bool includeFiles}) async {
    state = state.copyWith(phase: LinkPhase.sending, peerId: targetPeer);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (acceptError != null) throw acceptError!;
  }

  @override
  Future<void> declinePush(String targetPeer) async {
    state = const DeviceLinkState();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (declineError != null) throw declineError!;
  }

  @override
  Future<void> enterCode(String code,
      {required bool includeVault, required bool includeFiles}) async {
    enteredCode = code;
  }
}

late BuildContext _host;

Future<void> _pump(WidgetTester tester, DeviceLinkState seed) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      deviceLinkSyncProvider.overrideWith(() => _Link(seed)),
      overallConnectionProvider.overrideWithValue(OverallConnection.connected),
    ],
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Builder(builder: (context) {
        _host = context;
        return const SizedBox.expand();
      })),
    ),
  ));
}

void main() {
  setUp(() {
    _Link.acceptError = null;
    _Link.declineError = null;
    _Link.enteredCode = null;
  });

  const confirm = DeviceLinkState(phase: LinkPhase.confirmPush, peerId: 'dev2');

  testWidgets('a failed Send data ends on a plain failure, never stuck sending',
      (tester) async {
    _Link.acceptError = Exception('relay socket closed');
    await _pump(tester, confirm);
    showDeviceLinkDialog(_host, mode: DeviceLinkMode.showCode);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Send data'));
    await tester.pump();
    expect(find.text('Sending your data'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();

    expect(find.text('Sending your data'), findsNothing);
    expect(find.text('Link failed'), findsOneWidget);
    expect(find.textContaining("can't reach the relay"), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('Link failed'), findsNothing);
  });

  testWidgets('a failed Decline stays open with the reason', (tester) async {
    _Link.declineError = Exception('relay socket closed');
    await _pump(tester, confirm);
    showDeviceLinkDialog(_host, mode: DeviceLinkMode.showCode);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Decline'));
    await tester.pump();
    expect(find.text('Send your data?'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expect(find.text('Send your data?'), findsOneWidget);
    expect(find.textContaining("can't reach the relay"), findsOneWidget);
  });

  testWidgets('a declined request closes once the answer is sent',
      (tester) async {
    await _pump(tester, confirm);
    showDeviceLinkDialog(_host, mode: DeviceLinkMode.showCode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(find.text('Send your data?'), findsNothing);
  });

  testWidgets('a short code says why instead of doing nothing',
      (tester) async {
    await _pump(tester, const DeviceLinkState());
    showDeviceLinkDialog(_host, mode: DeviceLinkMode.enterCode);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ab3');
    await tester.tap(find.text('Link'));
    await tester.pumpAndSettle();
    expect(find.text('The code has 6 characters. Check it on your other device.'),
        findsOneWidget);
    expect(_Link.enteredCode, isNull);

    await tester.enterText(find.byType(TextField), 'ab3cd4');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(_Link.enteredCode, 'AB3CD4', reason: 'Enter submits');
  });

  testWidgets('receiving shows the shared progress bar', (tester) async {
    await _pump(
        tester,
        const DeviceLinkState(
            phase: LinkPhase.receiving, bytesReceived: 512, totalBytes: 1024));
    showDeviceLinkDialog(_host, mode: DeviceLinkMode.enterCode);
    await tester.pumpAndSettle();
    expect(find.byType(HollowProgressBar), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}

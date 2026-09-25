import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/twitch_join_dialog.dart';

class _Calls extends TwitchJoinCalls {
  _Calls({this.connected = true});

  final bool connected;
  Object? joinError;
  Object? startError;
  final joinCompleter = Completer<void>();
  int joins = 0;

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<twitch_api.TwitchDeviceFlowResult> startDeviceFlow() async {
    if (startError != null) throw startError!;
    return twitch_api.TwitchDeviceFlowResult(
      userCode: 'WDJB-MJHT',
      verificationUri: 'https://www.twitch.tv/activate',
      deviceCode: 'dev',
      intervalSecs: BigInt.from(5),
    );
  }

  @override
  Future<void> pollForToken(String deviceCode, int intervalSecs) =>
      Completer<void>().future;

  @override
  Future<void> ensureToken() async {}

  @override
  Future<String> verifyFollow(String broadcasterId) async => '{"proof":1}';

  @override
  Future<void> joinServer(String serverId, String proof) async {
    joins++;
    if (joinError != null) throw joinError!;
  }
}

late BuildContext _host;

Future<void> _pump(WidgetTester tester, {List<Override> overrides = const []}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: Builder(builder: (context) {
        _host = context;
        return const SizedBox.expand();
      })),
    ),
  ));
}

void _openTwitch({String channelId = 'chan1', String? failureReason}) {
  showTwitchJoinDialog(
    _host,
    serverId: 'srv1',
    channelId: channelId,
    channelName: 'somestreamer',
    serverName: 'Stream Friends',
    minFollowDays: 30,
    requireSub: false,
    failureReason: failureReason,
  );
}

void main() {
  group('Twitch join dialog', () {
    testWidgets('a join that throws lands on a plain failure, not Verifying',
        (tester) async {
      final calls = _Calls()..joinError = Exception('relay socket closed');
      await _pump(tester,
          overrides: [twitchJoinCallsProvider.overrideWithValue(calls)]);
      _openTwitch();
      await tester.pumpAndSettle();

      expect(calls.joins, 1);
      expect(find.text("Couldn't join Stream Friends"), findsOneWidget);
      expect(find.textContaining('Verifying'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing,
          reason: 'the raw exception never reaches the person');
      expect(find.textContaining("can't reach the relay"), findsOneWidget);
      expect(find.widgetWithText(HollowButton, 'Try again'), findsOneWidget);
    });

    testWidgets('a connected account never flashes the requirements',
        (tester) async {
      final calls = _Calls();
      await _pump(tester,
          overrides: [twitchJoinCallsProvider.overrideWithValue(calls)]);
      _openTwitch();
      await tester.pump();
      expect(find.text('Connect Twitch'), findsNothing);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Verifying your Twitch account…'), findsOneWidget);
      expect(find.text('Connect Twitch'), findsNothing);
      // Nothing answers the join here; close so no spinner is left running.
      Navigator.of(_host).pop();
      await tester.pumpAndSettle();
    });

    testWidgets('Connect Twitch failing stays on the step with the reason',
        (tester) async {
      final calls = _Calls(connected: false)
        ..startError = const FriendlyException('Twitch is down right now.');
      await _pump(tester,
          overrides: [twitchJoinCallsProvider.overrideWithValue(calls)]);
      _openTwitch();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect Twitch'));
      await tester.pumpAndSettle();
      expect(find.text('Twitch is down right now.'), findsOneWidget);
      expect(find.text('Connect Twitch'), findsOneWidget);
    });

    testWidgets('the device code is a copy field, no exclamation marks',
        (tester) async {
      final calls = _Calls(connected: false);
      await _pump(tester,
          overrides: [twitchJoinCallsProvider.overrideWithValue(calls)]);
      _openTwitch();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect Twitch'));
      await tester.pump();
      await tester.pump();
      expect(find.text('WDJB-MJHT'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy code'), findsOneWidget);
      expect(find.textContaining('!'), findsNothing);
      // The poll never answers; close the dialog so no timer is left.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('a relayed rejection with no channel only closes',
        (tester) async {
      await _pump(tester,
          overrides: [twitchJoinCallsProvider.overrideWithValue(_Calls())]);
      _openTwitch(channelId: '', failureReason: 'You follow for 3 days, not 30.');
      await tester.pumpAndSettle();
      expect(find.text('You follow for 3 days, not 30.'), findsOneWidget);
      expect(find.byType(HollowDialogCloseButton), findsOneWidget);
      expect(find.byType(HollowButton), findsNothing);
    });
  });

  testWidgets('join rejected is information: a close, no OK', (tester) async {
    await _pump(tester);
    showJoinRejectedDialog(_host,
        title: 'Server is full', message: 'Stream Friends is full.');
    await tester.pumpAndSettle();
    expect(find.text('OK'), findsNothing);
    expect(find.byType(HollowDialogCloseButton), findsOneWidget);
  });

  group('NSFW consent', () {
    testWidgets('waits for the join and shows why it failed', (tester) async {
      await _pump(tester);
      final join = Completer<void>();
      final result = showNsfwConfirmDialog(_host,
          serverName: 'Late Night', onProceed: () => join.future);
      await tester.pumpAndSettle();
      await tester.tap(find.text('I am 18 or older, join'));
      await tester.pump();
      expect(find.text('Sensitive content warning'), findsOneWidget,
          reason: 'stays open while the join is sent');
      join.completeError(Exception('relay not connected'));
      await tester.pumpAndSettle();
      expect(find.textContaining("can't reach the relay"), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
    });

    testWidgets('closes once the join is sent', (tester) async {
      await _pump(tester);
      var sent = false;
      final result = showNsfwConfirmDialog(_host,
          serverName: 'Late Night', onProceed: () async => sent = true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('I am 18 or older, join'));
      await tester.pumpAndSettle();
      expect(sent, isTrue);
      expect(await result, isTrue);
      expect(find.text('Sensitive content warning'), findsNothing);
    });
  });
}

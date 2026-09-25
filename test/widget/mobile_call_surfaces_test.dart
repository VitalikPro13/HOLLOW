/// The phone call surfaces (design language session 23, `tmp3.txt` section 8)
/// and the DM call record line (5.7). The call bar's body OPENS the call (B3),
/// Accept on the incoming screen opens it too, Leave goes through the
/// conference-aware path (B6), and a call record is a quiet line that is never
/// a message.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/call_record.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/call_records_provider.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/message_row.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';
import 'package:hollow/src/ui/mobile/mobile_call_video_view.dart';
import 'package:hollow/src/ui/mobile/mobile_incoming_call.dart';
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

final _nav = GlobalKey<NavigatorState>();

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  List<Override> extra = const [],
  Widget Function(BuildContext, Widget?)? builder,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(overrides: [
    ...hollowTestOverrides(extra: extra),
    ringtonePathProvider.overrideWith(_NoRingtone.new),
    statusProvider.overrideWith(_QuietStatus.new),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: _nav,
      theme: HollowThemeData.dark(),
      builder: builder,
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

Finder _semantic(String label) => find.bySemanticsLabel(label);

DmCallRecord _record(CallOutcome outcome,
        {bool video = false,
        bool outgoing = true,
        Duration talked = const Duration(minutes: 4, seconds: 12),
        DateTime? at}) {
  final start = at ?? DateTime(2026, 9, 25, 14, 30);
  return DmCallRecord(
    callId: 'c-${outcome.name}-${start.millisecondsSinceEpoch}',
    peer: kFriendPeerId1,
    outgoing: outgoing,
    video: video,
    outcome: outcome,
    startedAt: start,
    connectedAt: outcome == CallOutcome.answered
        ? start.add(const Duration(seconds: 3))
        : null,
    endedAt: start.add(const Duration(seconds: 3)).add(talked),
  );
}

void main() {
  group('the minimised call', () {
    testWidgets('tapping its body opens the call (B3)', (tester) async {
      await _pump(
        tester,
        const Stack(children: [MobileMinimisedCall()]),
        extra: [
          callProvider.overrideWith(() => _InCall(CallState(
                status: CallStatus.active,
                peerId: kFriendPeerId1,
                callId: 'c1',
                direction: CallDirection.outgoing,
                startedAt: DateTime.now(),
              ))),
        ],
      );
      final open = find.bySemanticsLabel(RegExp(r'^Open the call with'));
      expect(open, findsOneWidget);
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.byType(MobileCallScreen), findsOneWidget);
      expect(_semantic('Minimise the call'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a voice room opens the room, and Leave leaves it (B6)',
        (tester) async {
      final room = _Room(const VoiceChannelState(
        currentServerId: 's1',
        currentChannelId: 'v1',
        currentChannelName: 'Jam room',
      ));
      await _pump(
        tester,
        const Stack(children: [MobileMinimisedCall()]),
        extra: [voiceChannelProvider.overrideWith(() => room)],
      );
      expect(find.text('Jam room'), findsOneWidget);
      await tester.tap(_semantic('Leave the room'));
      await tester.pump();
      expect(room.leaves, 1, reason: 'through leaveVoiceRoom');

      await tester.tap(_semantic('Open the room Jam room'));
      await tester.pumpAndSettle();
      expect(find.byType(MobileVoiceChannelRoute), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('ringing out offers Cancel, not Leave', (tester) async {
      await _pump(
        tester,
        const Stack(children: [MobileMinimisedCall()]),
        extra: [
          callProvider.overrideWith(() => _InCall(const CallState(
                status: CallStatus.ringing,
                peerId: kFriendPeerId1,
                callId: 'c1',
                direction: CallDirection.outgoing,
              ))),
        ],
      );
      expect(find.text('Calling'), findsOneWidget);
      expect(_semantic('Cancel'), findsOneWidget);
      expect(_semantic('Leave the call'), findsNothing);
    });

    testWidgets('nothing at all without a call', (tester) async {
      await _pump(tester, const Stack(children: [MobileMinimisedCall()]));
      expect(find.byType(DecoratedBox), findsNothing);
    });
  });

  group('incoming', () {
    testWidgets('Accept answers and opens the call screen (B3)',
        (tester) async {
      final calls = _InCall(const CallState(
        status: CallStatus.ringing,
        peerId: kFriendPeerId1,
        callId: 'c1',
        direction: CallDirection.incoming,
      ));
      await _pump(
        tester,
        const SizedBox.shrink(),
        extra: [callProvider.overrideWith(() => calls)],
        builder: (context, child) => Stack(children: [
          child!,
          MobileIncomingCallOverlay(navigatorKey: _nav),
        ]),
      );
      expect(find.text('Voice call'), findsOneWidget);
      expect(_semantic('Decline'), findsOneWidget);
      await tester.tap(_semantic('Accept'));
      await tester.pumpAndSettle();
      expect(calls.accepted, isTrue);
      expect(find.byType(MobileCallScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('control row', () {
    Widget row(List<MobileCallControl> controls) =>
        Align(
          alignment: Alignment.bottomCenter,
          child: MobileCallControlRow(controls: controls),
        );

    testWidgets('every control says its purpose; a word sits under each',
        (tester) async {
      await _pump(
        tester,
        row([
          muteControl(muted: true, onTap: () {}),
          deafenControl(deafened: false, onTap: () {}),
          cameraControl(on: false, onTap: () {}),
          shareControl(sharing: false, onTap: () {}),
          leaveControl(word: 'End', purpose: 'Leave the call', onTap: () {}),
        ]),
      );
      for (final label in [
        'Unmute',
        'Deafen',
        'Turn on camera',
        'Share your screen',
        'Leave the call',
      ]) {
        expect(_semantic(label), findsOneWidget, reason: label);
      }
      for (final word in ['Unmute', 'Deafen', 'Camera', 'Share', 'End']) {
        expect(find.text(word), findsOneWidget, reason: word);
      }
    });

    testWidgets('a seventh control shrinks the row to fit', (tester) async {
      await _pump(
        tester,
        row([
          for (var i = 0; i < 7; i++)
            muteControl(muted: false, onTap: () {}),
        ]),
      );
      final sizes = tester
          .widgetList<SizedBox>(find.byWidgetPredicate((w) =>
              w is SizedBox &&
              w.width != null &&
              w.width == w.height &&
              w.width! >= 40))
          .map((b) => b.width)
          .toSet();
      expect(sizes, {MobileCallMetrics.controlTight});
      expect(tester.takeException(), isNull);
    });
  });

  group('call records', () {
    test('say what happened, in words', () {
      expect(_record(CallOutcome.answered).label, 'Voice call, 4 minutes');
      expect(
          _record(CallOutcome.answered,
                  video: true, talked: const Duration(seconds: 45))
              .label,
          'Video call, 45 seconds');
      expect(
          _record(CallOutcome.answered,
                  talked: const Duration(hours: 1, minutes: 5))
              .label,
          'Voice call, 1 hour 5 minutes');
      expect(_record(CallOutcome.missed).label, 'Missed call');
      expect(_record(CallOutcome.cancelled).label, 'Cancelled call');
      expect(_record(CallOutcome.unanswered).label, 'Voice call, no answer');
      expect(CallOutcome.parse('from-the-future'), CallOutcome.unknown);
    });

    test('the ending is classified from what tore the call down', () {
      CallOutcome c(bool outgoing, bool pickedUp, bool connected,
              CallEndCause cause) =>
          classifyCallEnd(
              outgoing: outgoing,
              pickedUp: pickedUp,
              connected: connected,
              cause: cause);
      expect(c(true, true, true, CallEndCause.remoteEnd), CallOutcome.answered);
      expect(c(true, false, false, CallEndCause.localHangup),
          CallOutcome.cancelled);
      expect(c(true, false, false, CallEndCause.remoteReject),
          CallOutcome.unanswered);
      expect(c(true, false, false, CallEndCause.ringTimeout),
          CallOutcome.unanswered);
      expect(c(false, false, false, CallEndCause.localDecline),
          CallOutcome.declined);
      expect(c(false, false, false, CallEndCause.ringTimeout),
          CallOutcome.missed);
      expect(c(false, false, false, CallEndCause.remoteEnd),
          CallOutcome.missed);
      expect(c(false, true, false, CallEndCause.linkLost), CallOutcome.failed);
    });

    test('sit between the messages around them, by time', () {
      final t = DateTime(2026, 9, 25, 14);
      final early = _record(CallOutcome.missed,
          at: t.subtract(const Duration(hours: 1)));
      final mid = _record(CallOutcome.answered,
          at: t.add(const Duration(minutes: 5)));
      final late = _record(CallOutcome.cancelled,
          at: t.add(const Duration(hours: 1)));
      final records = [early, mid, late];

      final first = callRecordsAround(
          records: records,
          previous: null,
          current: t,
          isNewest: false,
          historyComplete: false);
      expect(first.before, isEmpty,
          reason: 'older than a partial window: left out');
      final firstWhole = callRecordsAround(
          records: records,
          previous: null,
          current: t,
          isNewest: false,
          historyComplete: true);
      expect(firstWhole.before, [early]);

      final second = callRecordsAround(
          records: records,
          previous: t,
          current: t.add(const Duration(minutes: 30)),
          isNewest: true,
          historyComplete: true);
      expect(second.before, [mid]);
      expect(second.after, [late]);
    });

    testWidgets('render as a quiet line above the next message',
        (tester) async {
      final t = DateTime(2026, 9, 25, 14);
      await _pump(
        tester,
        dateSeparatedChatRow(
          rowKey: 'm2',
          timestamp: t.add(const Duration(minutes: 30)),
          prevTimestamp: t,
          showHeader: true,
          callsBefore: [
            _record(CallOutcome.answered, at: t.add(const Duration(minutes: 5)))
          ],
          child: const Text('the next message'),
        ),
      );
      final line = find.text('Voice call, 4 minutes');
      expect(line, findsOneWidget);
      expect(find.byType(CallRecordRow), findsOneWidget);
      expect(tester.getTopLeft(line).dy,
          lessThan(tester.getTopLeft(find.text('the next message')).dy));
      expect(_semantic('Voice call, 4 minutes, 14:05'), findsOneWidget);
    });

    testWidgets('a call record is never a message and never unread',
        (tester) async {
      final container = await _pump(tester, const SizedBox.shrink());
      container
          .read(dmCallRecordsProvider(kFriendPeerId1).notifier)
          .add(_record(CallOutcome.missed, outgoing: false));
      await tester.pump();
      expect(container.read(dmCallRecordsProvider(kFriendPeerId1)).length, 1);
      expect(container.read(chatProvider)[kFriendPeerId1] ?? const [],
          isEmpty,
          reason: 'records live beside the messages, never among them');
      final chat = [
        ChatMessage(
            text: 'hi',
            isMe: false,
            timestamp: DateTime(2026, 9, 25, 14),
            messageId: 'm1'),
      ];
      expect(
        unreadDividerIndex(
          count: chat.length,
          entrySeenId: 'm1',
          messageIdAt: (i) => chat[i].messageId,
          isMineAt: (i) => chat[i].isMe,
        ),
        isNull,
        reason: 'read up to m1; the missed call after it opens no new run',
      );
    });
  });
}

class _InCall extends CallNotifier {
  final CallState initial;
  bool accepted = false;
  _InCall(this.initial);

  @override
  CallState build() => initial;

  @override
  Future<void> acceptCall() async {
    accepted = true;
    state = state.copyWith(status: CallStatus.connecting);
  }
}

class _Room extends VoiceChannelNotifier {
  final VoiceChannelState initial;
  int leaves = 0;
  _Room(this.initial);

  @override
  VoiceChannelState build() => initial;

  @override
  Future<void> leaveChannel() async {
    leaves++;
  }
}

/// The relay status feed polls on a timer; nothing here needs it.
class _QuietStatus extends StatusNotifier {
  @override
  StatusState build() => const StatusState();
}

class _NoRingtone extends RingtonePathNotifier {
  @override
  Future<String?> build() async => null;
}

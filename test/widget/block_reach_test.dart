// Apple 1.2: a block stops the person reaching us and takes what they put on
// screen away at once: no call either way, a header with nothing of theirs to
// act on, their typing, reactions, pins, search hits and requests gone, and the
// notifications they left withdrawn. The same holds when the block arrives
// from another of our devices (`load`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/pinned_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_actions.dart';
import 'package:hollow/src/ui/chat/chat_pane.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/chat/pinned_messages.dart';
import 'package:hollow/src/ui/chat/reaction_bar.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/peer_id_text.dart';
import 'package:hollow/src/ui/components/profile_identity_column.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// A nameless person: the header can show only the id.
const _nameless = '12D3KooWQx7sDyFh1Yt6bNw5rVb8cJ2uLm3kPq9TzR4eHsGSi7bg';
const _bobDevice = 'device_of_bob_123';
const _bob = 'master_of_bob_456';

class _Api implements RustLibApi {
  final signals = <(String, String)>[];
  List<String> stored = const [];

  @override
  Future<void> crateApiNetworkCallSendSignal(
      {required String peerId,
      required String signalType,
      required String payload}) async {
    signals.add((peerId, signalType));
  }

  @override
  Future<void> crateApiStorageBlockPeer({required String peerId}) async {}

  @override
  Future<void> crateApiStorageUnblockPeer({required String peerId}) async {}

  @override
  Future<void> crateApiNetworkReportUser(
      {required String target, required String category}) async {}

  @override
  Future<List<String>> crateApiStorageLoadBlockedPeers() async => stored;

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() => const DeviceLinkState(links: {_bobDevice: _bob});
}

class _InCall extends CallNotifier {
  _InCall(this.initial);
  final CallState initial;
  @override
  CallState build() {
    super.build();
    return initial;
  }
}

class _Sink extends OsNotificationSink {
  _Sink(this.withdrawn);
  final List<Set<String>> withdrawn;
  @override
  Future<void> withdrawPerson(Set<String> ids) async => withdrawn.add(ids);
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

bool _hasButton(String label) => find
    .byWidgetPredicate((w) => w is HollowIconButton && w.label == label)
    .evaluate()
    .isNotEmpty;

Future<ProviderContainer> _pumpDesktopDm(WidgetTester tester, String peer,
    {double width = 1280}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      deviceLinkProvider.overrideWith(_Links.new),
      connectionStatusProvider.overrideWith(TestRelayStatus.new),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: ChatPane(peerId: peer)),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(tester.element(find.byType(ChatPane)));
}

Future<ProviderContainer> _pumpPhoneDm(WidgetTester tester, String peer,
    {double width = 375,
    RelayConnectionStatus relay = RelayConnectionStatus.connected}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      deviceLinkProvider.overrideWith(_Links.new),
      connectionStatusProvider.overrideWith(() => TestRelayStatus(relay)),
    ]),
    child: MaterialApp(
      navigatorKey: nav,
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: Text('home')),
    ),
  ));
  unawaited(nav.currentState!.push(hollowMobileRoute<void>(
    settings: const RouteSettings(name: MobileChatRoute.routeName),
    builder: (_) => MobileChatRoute(peerId: peer),
  )));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  return ProviderScope.containerOf(tester.element(find.byType(MobileChatRoute)));
}

void main() {
  final api = _Api();
  setUpAll(() {
    RustLib.initMock(api: api);
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });
  setUp(() {
    api.signals.clear();
    api.stored = const [];
  });

  group('the DM header', () {
    testWidgets('desktop: no call, video, search or bell once blocked',
        (tester) async {
      final c = await _pumpDesktopDm(tester, kFriendPeerId1);
      expect(_hasButton('Start voice call'), isTrue);
      expect(_hasButton('Start video call'), isTrue);
      expect(_hasButton('Search messages'), isTrue);
      expect(_hasButton('Mute notifications'), isTrue,
          reason: 'the profile panel is open at this width');

      unawaited(c.read(blockedUsersProvider.notifier).block(kFriendPeerId1));
      await tester.pump();
      expect(_hasButton('Start voice call'), isFalse);
      expect(_hasButton('Start video call'), isFalse);
      expect(_hasButton('Search messages'), isFalse);
      expect(_hasButton('Mute notifications'), isFalse);
      expect(_hasButton('Show profile') || _hasButton('Hide profile'), isTrue,
          reason: 'the profile, where Unblock lives, stays');
      expect(find.textContaining('You blocked'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('phone: back and the name only once blocked', (tester) async {
      final c = await _pumpPhoneDm(tester, kFriendPeerId1);
      expect(_hasButton('Voice call'), isTrue);
      expect(_hasButton('Video call'), isTrue);
      expect(_hasButton('Search messages'), isTrue);
      expect(_hasButton('Mute notifications'), isTrue);

      unawaited(c.read(blockedUsersProvider.notifier).block(kFriendPeerId1));
      await tester.pump();
      expect(_hasButton('Voice call'), isFalse);
      expect(_hasButton('Video call'), isFalse);
      expect(_hasButton('Search messages'), isFalse);
      expect(_hasButton('Mute notifications'), isFalse);
      expect(_hasButton('Back'), isTrue);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a block from another of our devices clears the header too',
        (tester) async {
      final c = await _pumpPhoneDm(tester, kFriendPeerId1);
      expect(_hasButton('Voice call'), isTrue);
      api.stored = [kFriendPeerId1];
      await c.read(blockedUsersProvider.notifier).load();
      await tester.pump();
      expect(_hasButton('Voice call'), isFalse);
      expect(find.textContaining('You blocked'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    for (final (form, width) in [('phone', 320.0), ('desktop', 800.0)]) {
      testWidgets('$form: a nameless person keeps the id ending in the title',
          (tester) async {
        if (form == 'phone') {
          await _pumpPhoneDm(tester, _nameless, width: width);
        } else {
          await _pumpDesktopDm(tester, _nameless, width: width);
        }
        final title = find.byType(PeerIdText);
        expect(title, findsOneWidget);
        final shown = tester.renderObject<RenderPeerIdText>(title).shown;
        expect(shown.endsWith(_nameless.substring(_nameless.length - 6)),
            isTrue,
            reason: 'got "$shown"');
        await tester.pump(const Duration(seconds: 2));
      });
    }
  });

  group('the profile card', () {
    Future<ProviderContainer> pumpCard(
        WidgetTester tester, String peer, ProfileCardDensity density) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          deviceLinkProvider.overrideWith(_Links.new),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProfileIdentityColumn(
                peerId: peer,
                density: density,
                width: kProfileColumnWidth,
                dismissHost: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      return ProviderScope.containerOf(
          tester.element(find.byType(ProfileIdentityColumn)));
    }

    for (final density in [ProfileCardDensity.full, ProfileCardDensity.touch]) {
      testWidgets('${density.name}: a blocked friend shows Blocked and Unblock',
          (tester) async {
        final c = await pumpCard(tester, kFriendPeerId1, density);
        expect(find.text('Friend'), findsOneWidget);
        expect(find.text('Message'), findsOneWidget);

        unawaited(c.read(blockedUsersProvider.notifier).block(kFriendPeerId1));
        await tester.pump();
        expect(find.text('Blocked'), findsOneWidget);
        expect(find.text('Unblock'), findsOneWidget);
        expect(find.text('Friend'), findsNothing);
        expect(find.text('Message'), findsNothing);
        expect(find.text('Online'), findsNothing);
        expect(find.text('Offline'), findsNothing);

        await tester.tap(find.text('Unblock'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Blocked'), findsNothing);
        expect(find.text('Friend'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
      });

      testWidgets('${density.name}: a blocked stranger is offered no Add friend',
          (tester) async {
        final c = await pumpCard(tester, _nameless, density);
        expect(find.text('Add friend'), findsOneWidget);
        unawaited(c.read(blockedUsersProvider.notifier).block(_nameless));
        await tester.pump();
        expect(find.text('Add friend'), findsNothing);
        expect(find.text('Unblock'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
      });
    }

    testWidgets('a device id finds its blocked master', (tester) async {
      final c = await pumpCard(tester, _bobDevice, ProfileCardDensity.compact);
      unawaited(c.read(blockedUsersProvider.notifier).block(_bob));
      await tester.pump();
      expect(find.text('Blocked'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('the phone DM header while offline', () {
    for (final width in [320.0, 375.0]) {
      testWidgets('fits at $width px', (tester) async {
        await _pumpPhoneDm(tester, kFriendPeerId1,
            width: width, relay: RelayConnectionStatus.disconnected);
        expect(tester.takeException(), isNull);
        expect(_hasButton('Voice call'), isTrue);
        expect(_hasButton('Mute notifications'), isTrue);
        expect(find.text('Offline'), width < 360 ? findsNothing : findsWidgets);
        await tester.pump(const Duration(seconds: 2));
      });
    }
  });

  group('calls', () {
    ProviderContainer container({CallState? call}) {
      final c = ProviderContainer(overrides: hollowTestOverrides(extra: [
        deviceLinkProvider.overrideWith(_Links.new),
        if (call != null) callProvider.overrideWith(() => _InCall(call)),
      ]));
      addTearDown(c.dispose);
      return c;
    }

    testWidgets('every call button says why it cannot ring a blocked person',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          deviceLinkProvider.overrideWith(_Links.new),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => startDmCallFlow(context, ref, _bob),
                child: const Text('call'),
              ),
            ),
          ),
        ),
      ));
      final c = ProviderScope.containerOf(tester.element(find.text('call')));
      await c.read(blockedUsersProvider.notifier).block(_bob);
      await tester.tap(find.text('call'));
      await tester.pump();
      expect(find.text('Unblock this person to call them'), findsOneWidget);
      expect(c.read(callProvider).status, CallStatus.idle);
      await tester.pump(const Duration(seconds: 6));
    });

    test('a call to someone blocked never starts', () async {
      final c = container();
      await c.read(blockedUsersProvider.notifier).block(_bob);
      await c.read(callProvider.notifier).startCall(_bob);
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(api.signals, isEmpty, reason: 'no invite leaves');
    });

    test('an invite from a blocked person never rings', () async {
      final c = container();
      await c.read(blockedUsersProvider.notifier).block(_bob);
      await c.read(callProvider.notifier).handleCallSignal(
          _bob, 'invite', '{"call_id":"c1","video":false,"sframe_key":"k"}');
      expect(c.read(callProvider).status, CallStatus.idle);
      expect(api.signals, isEmpty, reason: 'not even a busy answer');
    });

    test('blocking the person on the other end ends the call', () async {
      final c = container(
          call: const CallState(
        status: CallStatus.active,
        peerId: _bob,
        callId: 'c1',
        direction: CallDirection.outgoing,
      ));
      c.read(callProvider);
      unawaited(c.read(blockedUsersProvider.notifier).block(_bob));
      await pumpEventQueue();
      expect(api.signals, contains((_bob, 'end')));
    });

    test('a call with someone else carries on', () async {
      final c = container(
          call: const CallState(
        status: CallStatus.active,
        peerId: kFriendPeerId2,
        callId: 'c1',
        direction: CallDirection.outgoing,
      ));
      c.read(callProvider);
      unawaited(c.read(blockedUsersProvider.notifier).block(_bob));
      await pumpEventQueue();
      expect(api.signals, isEmpty);
      expect(c.read(callProvider).status, CallStatus.active);
    });
  });

  group('what they left on screen', () {
    test('their friend request leaves every list', () {
      final c = ProviderContainer(overrides: hollowTestOverrides());
      addTearDown(c.dispose);
      expect(c.read(incomingFriendRequestsProvider).map((f) => f.peerId),
          [kFriendPeerId3]);
      expect(c.read(pendingFriendCountProvider), 1);
      unawaited(c.read(blockedUsersProvider.notifier).block(kFriendPeerId3));
      expect(c.read(incomingFriendRequestsProvider), isEmpty);
      expect(c.read(pendingFriendCountProvider), 0);
    });

    test('their unread badge clears, and only theirs', () async {
      final c = ProviderContainer(overrides: hollowTestOverrides(extra: [
        deviceLinkProvider.overrideWith(_Links.new),
        unreadProvider.overrideWith(UnreadNotifier.new),
      ]));
      addTearDown(c.dispose);
      final unread = c.read(unreadProvider.notifier);
      unread.onDmMessage(_bob, 'm1', false);
      unread.onDmMessage(kFriendPeerId2, 'm2', false);
      unawaited(c.read(blockedUsersProvider.notifier).block(_bob));
      await pumpEventQueue();
      expect(c.read(unreadProvider).dmUnreadCounts, {kFriendPeerId2: 1});
    });

    test('their notifications are withdrawn, from every device of theirs',
        () async {
      final withdrawn = <Set<String>>[];
      final c = ProviderContainer(overrides: hollowTestOverrides(extra: [
        deviceLinkProvider.overrideWith(_Links.new),
        osNotificationSinkProvider.overrideWithValue(_Sink(withdrawn)),
      ]));
      addTearDown(c.dispose);
      await c.read(blockedUsersProvider.notifier).block(_bob);
      await pumpEventQueue();
      expect(withdrawn, [
        {_bob, _bobDevice}
      ]);

      // A sibling's block, learned through load(), withdraws too, once.
      api.stored = [_bob, kFriendPeerId2];
      await c.read(blockedUsersProvider.notifier).load();
      await pumpEventQueue();
      expect(withdrawn.last, {kFriendPeerId2});
      expect(withdrawn, hasLength(2));
    });

    testWidgets('their reactions are neither shown nor counted',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          deviceLinkProvider.overrideWith(_Links.new),
        ]),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(
            body: ReactionBar(
              reactions: {
                '👍': [_bobDevice, 'carol'],
                '🎉': [_bobDevice],
              },
              localPeerId: 'me',
            ),
          ),
        ),
      ));
      expect(find.text('2'), findsOneWidget);
      expect(find.text('🎉'), findsOneWidget);
      final c = ProviderScope.containerOf(tester.element(find.byType(ReactionBar)));
      unawaited(c.read(blockedUsersProvider.notifier).block(_bob));
      await tester.pump();
      expect(find.text('2'), findsNothing);
      expect(find.text('1'), findsOneWidget, reason: "carol's stays");
      expect(find.text('🎉'), findsNothing);
    });

    testWidgets('their typing is not shown', (tester) async {
      late Set<String> typing;
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(extra: [
          deviceLinkProvider.overrideWith(_Links.new),
        ]),
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            typing = typingMastersFor(ref, {_bobDevice, 'carol'});
            return const SizedBox();
          }),
        ),
      ));
      expect(typing, {_bob, 'carol'});
      final c = ProviderScope.containerOf(tester.element(find.byType(SizedBox)));
      unawaited(c.read(blockedUsersProvider.notifier).block(_bob));
      await tester.pump();
      expect(typing, {'carol'});
    });

    test('their pins are not listed, nor counted as further back', () {
      final mine = ChannelChatMessage(
          senderId: 'carol', text: 'a', isMe: false, messageId: 'p1');
      final theirs = ChannelChatMessage(
          senderId: _bobDevice, text: 'b', isMe: false, messageId: 'p2');
      final r = resolvePinnedMessages(['p1', 'p2', 'p-old'], [mine, theirs],
          hiddenAuthor: (id) => id == _bobDevice);
      expect(r.loaded.map((m) => m.messageId), ['p1']);
      expect(r.missing, 1);
    });

    test('the header pin count skips their loaded pins', () {
      final c = ProviderContainer(overrides: hollowTestOverrides(extra: [
        deviceLinkProvider.overrideWith(_Links.new),
      ]));
      addTearDown(c.dispose);
      const key = 'srv:general';
      c.read(pinnedProvider.notifier).state = {
        key: ['p1', 'p2', 'p-old']
      };
      c.read(channelChatProvider.notifier).state = {
        key: [
          ChannelChatMessage(
              senderId: 'carol', text: 'a', isMe: false, messageId: 'p1'),
          ChannelChatMessage(
              senderId: _bobDevice, text: 'b', isMe: false, messageId: 'p2'),
        ],
      };
      final sub = c.listen(shownPinCountProvider(key), (_, _) {});
      addTearDown(sub.close);
      expect(sub.read(), 3);
      unawaited(c.read(blockedUsersProvider.notifier).block(_bob));
      expect(sub.read(), 2,
          reason: 'one pin of theirs is loaded; the old one cannot be judged');
    });

    testWidgets('their search hits are not listed', (tester) async {
      final results = ChatSearchResults<String>()
        ..hits = ['carol: hello', 'bob: hello']
        ..query = 'hello';
      await tester.pumpWidget(MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: ChatSearchResultsView<String>(
            results: results,
            hidden: (hit) => hit.startsWith('bob'),
            itemBuilder: Text.new,
            onRetry: () {},
          ),
        ),
      ));
      expect(find.text('carol: hello'), findsOneWidget);
      expect(find.text('bob: hello'), findsNothing);
    });
  });
}

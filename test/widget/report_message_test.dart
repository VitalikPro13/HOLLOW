// Apple 1.2: Report on someone else's message, aimed at the author's MASTER
// identity with nothing of the message attached, then Block in the same flow;
// a block itself sends one anonymous `blocked` count and hides the person at
// once.
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_message_actions.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

const _device = 'device_of_bob_123';
const _master = 'master_of_bob_456';
const _text = 'the words of the message';
const _mid = 'mid-0001';

/// Records every report and block; everything else stays pending.
class _Api implements RustLibApi {
  final reports = <(String, String)>[];
  final blocks = <String>[];
  bool failBlock = false;

  @override
  Future<void> crateApiNetworkReportUser(
      {required String target, required String category}) async {
    reports.add((target, category));
  }

  @override
  Future<void> crateApiStorageBlockPeer({required String peerId}) async {
    if (failBlock) throw Exception('store closed');
    blocks.add(peerId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() => const DeviceLinkState(links: {_device: _master});
}

class _Blocked extends BlockedUsersNotifier {
  _Blocked(this.initial);
  final Set<String> initial;
  @override
  Set<String> build() => initial;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

List<Override> _overrides({Set<String> blocked = const {}}) => hollowTestOverrides(extra: [
      deviceLinkProvider.overrideWith(_Links.new),
      blockedUsersProvider.overrideWith(() => _Blocked(blocked)),
    ]);

/// One message row wired the way the chat panes wire it.
Future<void> _pumpRow(WidgetTester tester,
    {required bool isMe, String sender = _device, Set<String> blocked = const {}}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: _overrides(blocked: blocked),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: MessageActionBarScope(
          child: Consumer(builder: (context, ref, _) {
            final links = ref.watch(deviceLinkProvider);
            return MessageHoverWrapper(
              isMe: isMe,
              messageId: _mid,
              currentText: _text,
              onReply: () {},
              onReport: reportMessageAction(context,
                  isMe: isMe,
                  senderMaster: links.identityOf(sender),
                  displayName: 'Bob'),
              child: const SizedBox(height: 40, child: Text(_text)),
            );
          }),
        ),
      ),
    ),
  ));
}

Future<void> _rightClick(WidgetTester tester) async {
  await tester.tapAt(tester.getCenter(find.text(_text)),
      buttons: kSecondaryButton, kind: PointerDeviceKind.mouse);
  await tester.pumpAndSettle();
}

void main() {
  final api = _Api();
  setUpAll(() {
    RustLib.initMock(api: api);
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });
  setUp(() {
    api.reports.clear();
    api.blocks.clear();
    api.failBlock = false;
  });

  testWidgets('a report names the author master and nothing of the message, '
      'then offers Block in the same dialog', (tester) async {
    await _pumpRow(tester, isMe: false);
    await _rightClick(tester);
    await tester.tap(find.text('Report message'));
    await tester.pumpAndSettle();
    expect(find.textContaining('message itself never leaves this device'),
        findsOneWidget);

    await tester.tap(find.text('Harassment'));
    await tester.pump();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();

    expect(api.reports, [(_master, 'harassment')],
        reason: 'the MASTER identity, never the device that sent it');
    for (final (target, category) in api.reports) {
      for (final field in [target, category]) {
        expect(field.contains(_text) || field.contains(_mid), isFalse);
      }
    }

    expect(find.text('Report sent'), findsOneWidget);
    expect(find.text('Do you also want to block Bob?'), findsOneWidget);
    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();

    expect(api.blocks, [_master]);
    expect(api.reports, [(_master, 'harassment'), (_master, 'blocked')]);
    expect(find.text('Report sent and Bob blocked'), findsOneWidget);
     // The toast's own timer.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Not now leaves the report alone and blocks nobody', (tester) async {
    await _pumpRow(tester, isMe: false);
    await _rightClick(tester);
    await tester.tap(find.text('Report message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam'));
    await tester.pump();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(api.reports, [(_master, 'spam')]);
    expect(api.blocks, isEmpty);
     // The toast's own timer.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('someone already blocked is not offered a block again',
      (tester) async {
    await _pumpRow(tester, isMe: false, blocked: {_master});
    await _rightClick(tester);
    await tester.tap(find.text('Report message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam'));
    await tester.pump();
    await tester.tap(find.text('Report'));
    await tester.pumpAndSettle();
    expect(find.text('Not now'), findsNothing);
    expect(api.reports, [(_master, 'spam')]);
     // The toast's own timer.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('no Report on our own message', (tester) async {
    await _pumpRow(tester, isMe: true, sender: kLocalPeerId);
    await _rightClick(tester);
    expect(find.text('Report message'), findsNothing);
  });

  testWidgets('the menu itself never offers Report on our own message',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: MessageActionBarScope(
            child: MessageHoverWrapper(
              isMe: true,
              messageId: _mid,
              currentText: _text,
              onReply: () {},
              onReport: () {},
              child: const SizedBox(height: 40, child: Text(_text)),
            ),
          ),
        ),
      ),
    ));
    await _rightClick(tester);
    expect(find.text('Reply'), findsOneWidget);
    expect(find.text('Report message'), findsNothing);
  });

  testWidgets('no Report on a message from another device of ours',
      (tester) async {
    await _pumpRow(tester, isMe: false, sender: kLocalPeerId);
    await _rightClick(tester);
    expect(find.text('Report message'), findsNothing);
  });

  testWidgets('the phone sheet offers Report for others only', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext host;
    await tester.pumpWidget(ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (c) {
          host = c;
          return const SizedBox.expand();
        })),
      ),
    ));
    var reported = 0;
    for (final isMe in [true, false]) {
      showMobileMessageActions(
        context: host,
        messageText: _text,
        senderName: 'Bob',
        timestamp: '12:00',
        isMe: isMe,
        onReport: () => reported++,
      );
      await tester.pumpAndSettle();
      expect(find.text('Report message'), isMe ? findsNothing : findsOneWidget);
      if (!isMe) {
        await tester.tap(find.text('Report message'));
        await tester.pumpAndSettle();
      } else {
        Navigator.of(host).pop();
        await tester.pumpAndSettle();
      }
    }
    expect(reported, 1);
  });

  group('blocking', () {
    ProviderContainer container() {
      final c = ProviderContainer(overrides: hollowTestOverrides());
      addTearDown(c.dispose);
      return c;
    }

    test('sends one anonymous blocked count, once', () async {
      final c = container();
      await c.read(blockedUsersProvider.notifier).block(_master);
      await c.read(blockedUsersProvider.notifier).block(_master);
      await pumpEventQueue();
      expect(api.reports, [(_master, kBlockedReportCategory)]);
    });

    test('a block that did not save sends nothing', () async {
      api.failBlock = true;
      final c = container();
      await expectLater(
          c.read(blockedUsersProvider.notifier).block(_master), throwsException);
      await pumpEventQueue();
      expect(api.reports, isEmpty);
      expect(c.read(blockedUsersProvider), isEmpty);
    });

    test('a blocked friend leaves every conversation list at once', () async {
      final c = container();
      expect(c.read(sortedFriendsProvider).map((f) => f.peerId),
          contains(kFriendPeerId1));
      unawaited(c.read(blockedUsersProvider.notifier).block(kFriendPeerId1));
      expect(c.read(sortedFriendsProvider).map((f) => f.peerId),
          isNot(contains(kFriendPeerId1)));
    });

    testWidgets('an open DM on a phone swaps to the notice the moment the '
        'block lands', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          navigatorKey: nav,
          theme: HollowThemeData.dark(),
          home: const Scaffold(body: Text('home')),
        ),
      ));
      unawaited(nav.currentState!.push(hollowMobileRoute<void>(
        settings: const RouteSettings(name: MobileChatRoute.routeName),
        builder: (_) => const MobileChatRoute(peerId: kFriendPeerId1),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(EditableText), findsWidgets);
      expect(find.textContaining('You blocked'), findsNothing);

      final c = ProviderScope.containerOf(
          tester.element(find.byType(MobileChatRoute)));
      unawaited(c.read(blockedUsersProvider.notifier).block(kFriendPeerId1));
      await tester.pump();
      expect(find.textContaining('You blocked'), findsOneWidget);
      expect(find.text('Unblock'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(MobileChatRoute),
              matching: find.byType(EditableText)),
          findsNothing,
          reason: 'no composer to a blocked person');
      await tester.pump(const Duration(seconds: 2));
    });
  });

  test('every message surface reports the author through the resolver', () {
    String read(String p) =>
        File(p).readAsStringSync().replaceAll('\r\n', '\n');
    final desktopDm = read('lib/src/ui/chat/chat_pane.dart');
    expect(
        desktopDm.contains('onReport: reportMessageAction(context,\n'
            '          isMe: msg.isMe,\n'
            '          senderMaster: ref.read(deviceLinkProvider).identityOf(widget.peerId),'),
        isTrue);
    expect(desktopDm.contains('final blockedPeer = ref.watch(blockedUsersProvider).contains(peerMaster);'),
        isTrue);
    expect(desktopDm.contains('else if (blockedPeer)\n            Expanded(\n              child: BlockedConversationNotice('),
        isTrue, reason: 'a desktop DM swaps to the notice when blocked');
    final channel = read('lib/src/ui/chat/channel_chat_pane.dart');
    expect(channel.contains('onReport: _reportFor(context, msg, links),'), isTrue);
    expect(channel.contains('final master = links.identityOf(msg.senderId);'), isTrue);
    final guest = read('lib/src/ui/guest/guest_chat_pane.dart');
    expect(guest.contains('senderMaster: links\n'), isTrue);
    expect(guest.contains('!blocked.contains(links.identityOf(m.senderId))'), isTrue);
    final phone = read('lib/src/ui/mobile/mobile_chat_route.dart');
    expect(
        phone.contains('senderMaster: ref.read(deviceLinkProvider).identityOf(widget.peerId!),'),
        isTrue);
    expect(
        phone.contains('senderMaster: ref.read(deviceLinkProvider).identityOf(msg.senderId),'),
        isTrue);
    expect(phone.contains('.where((m) => !blocked.contains(identityOf(m.senderId)))'),
        isTrue, reason: 'the phone channel hides a blocked author');
  });
}

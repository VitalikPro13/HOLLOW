import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_member_panel.dart';
import 'package:hollow/src/ui/mobile/mobile_notification_banner.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_channels.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_navigation.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_route.dart';
import 'package:hollow/src/ui/shell/clock_skew_banner.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// The phone's server page (#154): the banner that folds into the bar, the
/// channel list, the one way into a channel that leaves
/// [shell, server page, channel], the drags between list and channel, the
/// members panel, the switcher and system back.

/// Every FFI call stays pending, so pages sit in their loading states.
class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => testServers;
}

class _Banners extends ServerBannerNotifier {
  final Map<String, ServerBannerEntry> initial;
  _Banners(this.initial);

  @override
  Map<String, ServerBannerEntry> build() => initial;

  @override
  Future<void> loadBanner(String serverId) async {}
}

/// A 1x1 PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x60,
  0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// general and random, a "Hangout" category holding the voice room and lots
/// of filler so the list scrolls.
final _entries = <MobileChannelEntry>[
  MobileChannelRowEntry(testChannels[kChannelId1]!, null),
  MobileChannelRowEntry(testChannels[kChannelId2]!, null),
  const MobileCategoryEntry('Hangout'),
  MobileChannelRowEntry(testChannels[kVoiceChannelId]!, 'Hangout'),
  for (var i = 0; i < 30; i++)
    MobileChannelRowEntry(
        ChannelInfo(channelId: 'filler$i', name: 'filler-$i'), 'Hangout'),
];

/// Names of the routes on the stack, bottom first.
class _Stack extends NavigatorObserver {
  final routes = <Route<dynamic>>[];

  List<String> get names => [
        for (final r in routes)
          r.settings.name == kMobileServerRouteName
              ? 'server:${r.settings.arguments}'
              : r.settings.name == MobileChatRoute.routeName
                  ? 'channel:${(r.settings.arguments as MobileChannelRef?)?.channelId}'
                  : r.settings.name ?? (r is PopupRoute ? 'popup' : 'page'),
      ];

  @override
  void didPush(Route route, Route? previousRoute) => routes.add(route);
  @override
  void didPop(Route route, Route? previousRoute) => routes.remove(route);
  @override
  void didRemove(Route route, Route? previousRoute) => routes.remove(route);
  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    final i = routes.indexOf(oldRoute!);
    routes[i] = newRoute!;
  }
}

late _Stack _stack;
late GlobalKey<NavigatorState> _nav;

Future<void> _pumpHost(
  WidgetTester tester, {
  bool banner = true,
  Size size = const Size(400, 800),
  TextScaler textScaler = TextScaler.noScaling,
  List<Override> extra = const [],
  List<MobileChannelEntry>? entries,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _stack = _Stack();
  _nav = GlobalKey<NavigatorState>();
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      serverListProvider.overrideWith(_Servers.new),
      serverBannerProvider.overrideWith(() => _Banners({
            if (banner)
              kServerId1:
                  ServerBannerEntry(bytes: _png, hash: 'h1', animated: false),
          })),
      mobileServerChannelsProvider
          .overrideWith((ref, serverId) async => entries ?? _entries),
      serverChannelsProvider.overrideWith((ref, serverId) async =>
          serverId == kServerId1 ? testChannels : const {}),
      serverMembersProvider.overrideWith((ref, serverId) async => const []),
      myPermissionsProvider.overrideWith((ref, serverId) async => 0),
      myRoleProvider.overrideWith((ref, serverId) async => 'member'),
      serverListLoadStateProvider
          .overrideWith((_) => (loaded: true, error: null)),
      ...extra,
    ]),
    child: MaterialApp(
      navigatorKey: _nav,
      navigatorObservers: [_stack],
      theme: HollowThemeData.dark(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: const Scaffold(body: Text('shell')),
    ),
  ));
}

late WidgetTester _tester;

BuildContext get _shell =>
    _tester.element(find.text('shell', skipOffstage: false));

ProviderContainer get _container => ProviderScope.containerOf(_shell);

/// Frames plus a route transition, without waiting on spinners.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _openServer(WidgetTester tester) async {
  unawaited(openMobileServer(_shell, _UnusedRef(), kServerId1));
  await _settle(tester);
  expect(find.byType(MobileServerRoute), findsOneWidget);
}

/// The seam takes a ref; opening a server reads the container itself.
class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> _drag(WidgetTester tester, Offset from, Offset by) async {
  final gesture = await tester.startGesture(from);
  const steps = 20;
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(by / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 30));
  }
  await gesture.up();
  await _settle(tester);
}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _PendingApi());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  testWidgets('the page shows the banner, the server and its channels',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    expect(find.text('Test Server'), findsWidgets);
    expect(find.text('general'), findsOneWidget);
    expect(find.text('Hangout'), findsOneWidget);
    expect(find.bySemanticsLabel('Back to servers'), findsOneWidget);
    expect(find.bySemanticsLabel('Invite people'), findsOneWidget);
    expect(find.bySemanticsLabel('Server options'), findsOneWidget);
    expect(find.textContaining('0 online · 5 members'), findsWidgets);
  });

  testWidgets('the banner folds into the plain bar as the list scrolls',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    final header = find.byKey(kMobileServerHeaderKey);
    expect(tester.getSize(header).height, kMobileServerBannerHeight);
    await tester.drag(find.text('filler-3'), const Offset(0, -500));
    await _settle(tester);
    expect(tester.getSize(header).height, kMobileServerBarHeight);
    // Folded, the bar names the server and still opens the switcher.
    expect(find.bySemanticsLabel('Test Server, switch server'), findsWidgets);
  });

  testWidgets('a server with no banner keeps the plain bar', (tester) async {
    _tester = tester;
    await _pumpHost(tester, banner: false);
    await _openServer(tester);
    expect(tester.getSize(find.byKey(kMobileServerHeaderKey)).height,
        kMobileServerBarHeight);
  });

  testWidgets('a folded category hides its channels', (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    expect(find.text('Voice'), findsOneWidget);
    await tester.tap(find.text('Hangout'));
    await _settle(tester);
    expect(find.text('Voice'), findsNothing);
    expect(find.text('general'), findsOneWidget);
  });

  testWidgets('opening a channel from the shell leaves shell, server, channel',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    unawaited(openMobileChannelOn(_nav.currentState!,
        serverId: kServerId1, channelId: kChannelId1, channelName: 'general'));
    await _settle(tester);
    expect(_stack.names,
        ['/', 'server:$kServerId1', 'channel:$kChannelId1']);
    expect(_container.read(selectedChannelProvider), kChannelId1);
  });

  testWidgets('a channel tapped on the page stacks on it, once',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    expect(_stack.names, ['/', 'server:$kServerId1', 'channel:$kChannelId2']);
    // Another channel from anywhere replaces it, never stacks.
    unawaited(openMobileChannelOn(_nav.currentState!,
        serverId: kServerId1, channelId: kChannelId1, channelName: 'general'));
    await _settle(tester);
    expect(_stack.names, ['/', 'server:$kServerId1', 'channel:$kChannelId1']);
    // The replaced page's cleanup leaves the new selection alone.
    expect(_container.read(selectedChannelProvider), kChannelId1);
  });

  testWidgets('the channel already open stays put under a page above it',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    unawaited(_nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('above')))));
    await _settle(tester);
    unawaited(openMobileChannelOn(_nav.currentState!,
        serverId: kServerId1, channelId: kChannelId2, channelName: 'random'));
    await _settle(tester);
    expect(_stack.names, ['/', 'server:$kServerId1', 'channel:$kChannelId2']);
    expect(_container.read(selectedChannelProvider), kChannelId2);
  });

  test('the list holds only channels we may see, in the layout order', () {
    final entries = mobileChannelEntries({
      'a': const ChannelInfo(channelId: 'a', name: 'alpha'),
      'b': const ChannelInfo(channelId: 'b', name: 'beta', meCanSee: false),
      'c': const ChannelInfo(channelId: 'c', name: 'gamma'),
    }, '[{"type":"category","name":"Talk"},{"type":"channel","channel_id":"c"},'
        '{"type":"channel","channel_id":"b"}]');
    final names = [
      for (final e in entries)
        switch (e) {
          MobileCategoryEntry(:final name) => 'cat:$name',
          MobileChannelRowEntry(:final channel, :final category) =>
            '${channel.name}@$category',
          MobileSeparatorEntry() => '-',
        },
    ];
    // alpha is unplaced: appended after the trailing category, inside it.
    expect(names, ['cat:Talk', 'gamma@Talk', 'alpha@Talk']);
  });

  testWidgets('a push for another server lands under that server page',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    unawaited(openMobileChannelOn(_nav.currentState!,
        serverId: kServerId2, channelId: 'c9', channelName: 'news'));
    await _settle(tester);
    expect(_stack.names, ['/', 'server:$kServerId2', 'channel:c9']);
  });

  testWidgets('drag right from a channel lands on the list, left returns',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    expect(find.byType(MobileChatRoute), findsOneWidget);

    await _drag(tester, const Offset(150, 400), const Offset(220, 0));
    expect(find.byType(MobileChatRoute), findsNothing);
    expect(_stack.names, ['/', 'server:$kServerId1']);
    // The channel you were in stays marked and the selection is cleared.
    expect(_container.read(selectedChannelProvider), isNull);
    expect(_container.read(mobileLastChannelProvider)[kServerId1],
        kChannelId2);

    await _drag(tester, const Offset(300, 400), const Offset(-220, 0));
    expect(find.byType(MobileChatRoute), findsOneWidget);
    expect(_stack.names, ['/', 'server:$kServerId1', 'channel:$kChannelId2']);
    expect(_container.read(selectedChannelProvider), kChannelId2);
  });

  testWidgets('a short drag left from the list leaves the channel closed',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    _nav.currentState!.pop();
    await _settle(tester);
    await _drag(tester, const Offset(300, 400), const Offset(-60, 0));
    expect(_stack.names, ['/', 'server:$kServerId1']);
    expect(_container.read(selectedChannelProvider), isNull);
  });

  testWidgets('the members panel opens by the button and by a drag left',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);

    await tester.tap(find.bySemanticsLabel('Members'));
    await _settle(tester);
    expect(find.text('Members'), findsOneWidget);
    expect(find.bySemanticsLabel('Close members'), findsWidgets);
    await tester.tap(find.byIcon(LucideIcons.x));
    await _settle(tester);
    expect(find.bySemanticsLabel('Close members'), findsNothing);

    await _drag(tester, const Offset(300, 400), const Offset(-220, 0));
    expect(find.bySemanticsLabel('Close members'), findsWidgets);
    // Dragging the panel back toward its edge closes it.
    await _drag(tester, const Offset(200, 400), const Offset(200, 0));
    expect(find.bySemanticsLabel('Close members'), findsNothing);
    expect(find.byType(MobileChatRoute), findsOneWidget);
  });

  testWidgets('system back: panel, then channel, then server page',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    await tester.tap(find.bySemanticsLabel('Members'));
    await _settle(tester);

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await _settle(tester);
    }

    await back();
    expect(find.bySemanticsLabel('Close members'), findsNothing);
    expect(_stack.names, ['/', 'server:$kServerId1', 'channel:$kChannelId2']);
    await back();
    expect(_stack.names, ['/', 'server:$kServerId1']);
    await back();
    expect(_stack.names, ['/']);
  });

  testWidgets('the server sheet waits for our role, never offers an owner '
      'a leave', (tester) async {
    _tester = tester;
    final role = Completer<String>();
    final perms = Completer<int>();
    await _pumpHost(tester, extra: [
      myRoleProvider.overrideWith((ref, serverId) => role.future),
      myPermissionsProvider.overrideWith((ref, serverId) => perms.future),
    ]);
    await _openServer(tester);
    await tester.tap(find.bySemanticsLabel('Server options'));
    await _settle(tester);
    role.complete('owner');
    perms.complete(0x7fffffff);
    await _settle(tester);
    expect(find.text('Delete server'), findsOneWidget);
    expect(find.text('Leave server'), findsNothing);
    expect(find.text('Create channel'), findsWidgets);
  });

  testWidgets('the switcher replaces the page instead of stacking',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.bySemanticsLabel('Test Server, switch server').first);
    await _settle(tester);
    expect(find.text('Your servers'), findsOneWidget);
    await tester.tap(find.text('Dev Hangout'));
    await _settle(tester);
    expect(_stack.names, ['/', 'server:$kServerId2']);
  });

  testWidgets('under Reduce motion the members panel opens at once',
      (tester) async {
    final rm = ReduceMotionController.instance.effective;
    rm.value = true;
    HollowDurations.animationsDisabled = true;
    addTearDown(() {
      rm.value = false;
      HollowDurations.animationsDisabled = false;
    });
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    await tester.tap(find.bySemanticsLabel('Members'));
    await tester.pump();
    final panel = tester.state<MobileMemberSidePanelState>(
        find.byType(MobileMemberSidePanel));
    expect(panel.isOpen, isTrue);
    expect(tester.getTopRight(find.text('Members')).dx, lessThan(400));
  });

  for (final scale in [1.5, 2.0]) {
    testWidgets('text scale $scale holds on the page and the channel header',
        (tester) async {
      _tester = tester;
      await _pumpHost(tester,
          size: const Size(320, 640), textScaler: TextScaler.linear(scale));
      await _openServer(tester);
      expect(tester.takeException(), isNull);
      await tester.drag(find.text('filler-3'), const Offset(0, -400));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.drag(find.text('filler-9'), const Offset(0, 800));
      await _settle(tester);
      await tester.tap(find.text('random'));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the page leaves when its server leaves the list',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    _container.read(serverListProvider.notifier).onServerDeleted(kServerId1);
    await _settle(tester);
    expect(find.byType(MobileServerRoute), findsNothing);
    expect(_stack.names, ['/']);
  });

  // Review L14: category names are not unique (the desktop sidebar's menu
  // edits them by layout index for that reason). Two with one name must both
  // render and fold on their own.
  testWidgets('two categories with the same name fold on their own',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester, banner: false, entries: [
      const MobileCategoryEntry('Text'),
      MobileChannelRowEntry(testChannels[kChannelId1]!, 'Text'),
      const MobileCategoryEntry('Text'),
      MobileChannelRowEntry(testChannels[kChannelId2]!, 'Text'),
    ]);
    await _openServer(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('general'), findsOneWidget);
    expect(find.text('random'), findsOneWidget);
    await tester.tap(find.text('Text').first);
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('general'), findsNothing);
    expect(find.text('random'), findsOneWidget,
        reason: 'folding the first Text category folded the second too');
  });

  // Review L13: the page leaves under the sheet when its server goes; the
  // sheet must go with it, or every row is a dead tap.
  testWidgets('the switcher closes with the page when the server leaves',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.bySemanticsLabel('Test Server, switch server').first);
    await _settle(tester);
    expect(find.text('Your servers'), findsOneWidget);
    _container.read(serverListProvider.notifier).onServerDeleted(kServerId1);
    await _settle(tester);
    expect(find.text('Your servers'), findsNothing);
    expect(_stack.names, ['/']);
  });

  // Review L7: the shell and the channel page carry them; so does this page.
  testWidgets('the page carries the status and clock strips', (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    final page = find.byType(MobileServerRoute);
    expect(find.descendant(of: page, matching: find.byType(SystemStatusBanner)),
        findsOneWidget);
    expect(find.descendant(of: page, matching: find.byType(ClockSkewBanner)),
        findsOneWidget);
  });

  // Review L9: a voice room's chat is reached through the room (its text
  // chat may be off, or you left the room), never by the list's drag.
  testWidgets('the leftward drag never brings back a voice room',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    _container.read(mobileLastChannelProvider.notifier).state = {
      kServerId1: kVoiceChannelId,
    };
    await _openServer(tester);
    await _drag(tester, const Offset(300, 400), const Offset(-220, 0));
    expect(_stack.names, ['/', 'server:$kServerId1']);
    expect(find.byType(MobileChatRoute), findsNothing);
  });

  // Review L8: a banner for another conversation stays readable and
  // tappable while the members panel is open.
  testWidgets('the in-chat banner sits above the members panel',
      (tester) async {
    _tester = tester;
    await _pumpHost(tester);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    final stack = tester.widget<Stack>(find
        .ancestor(
            of: find.byType(MobileInChatBanner), matching: find.byType(Stack))
        .first);
    final banner = stack.children.indexWhere((w) => w is MobileInChatBanner);
    final panel = stack.children.indexWhere(
        (w) => w is Positioned && w.child is MobileMemberSidePanel);
    expect(banner, isNonNegative);
    expect(panel, isNonNegative);
    expect(banner, greaterThan(panel));
  });

  // From the review: the switcher title is one button that names the server
  // once to a screen reader.
  testWidgets('the switch-server title reads its name once', (tester) async {
    _tester = tester;
    final handle = tester.ensureSemantics();
    await _pumpHost(tester, banner: false);
    await _openServer(tester);
    final node = tester.getSemantics(find.text('Test Server').first);
    expect('Test Server'.allMatches(node.label).length, 1, reason: node.label);
    handle.dispose();
  });

  // The in-chat banner still surfaces a post in ANOTHER channel of the server
  // whose channel is open, above everything on the page.
  testWidgets('a post in another channel shows the in-chat banner',
      (tester) async {
    _tester = tester;
    final cards = _Cards();
    await _pumpHost(tester,
        extra: [systemNotificationProvider.overrideWith(() => cards)]);
    await _openServer(tester);
    await tester.tap(find.text('random'));
    await _settle(tester);
    cards.add(NotificationCard(
      sourceKey: '$kServerId1:$kChannelId1',
      title: 'Test Server > #general',
      avatarId: kServerId1,
      isDm: false,
      serverId: kServerId1,
      channelId: kChannelId1,
      messages: [
        NotificationMessage(
          senderPeerId: kFriendPeerId1,
          senderName: 'Ada',
          text: 'look at the general mix',
          timestamp: DateTime.now(),
        ),
      ],
    ));
    await _settle(tester);
    expect(find.text('Test Server > #general'), findsOneWidget);
    expect(tester.getRect(find.text('Test Server > #general')).top,
        greaterThan(0));
    // Its countdown runs out.
    await tester.pump(const Duration(seconds: 6));
    await _settle(tester);
  });
}

class _Cards extends SystemNotificationNotifier {
  void add(NotificationCard card) => state = [...state, card];
}

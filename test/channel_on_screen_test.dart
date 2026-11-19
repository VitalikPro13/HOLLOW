import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_on_screen_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/ui/guest/guest_chat_pane.dart';
import 'package:hollow/src/ui/mobile/channel_on_screen_route.dart';

const _general = (serverId: 'srv', channelId: 'general');

Set<ScreenChannel> _shown({
  bool windowVisible = true,
  bool windowMinimized = false,
  bool appBackground = false,
  bool appLocked = false,
  bool mobileShell = false,
  List<ScreenChannel> mobileRoutes = const [],
  String? selectedServer = 'srv',
  String? selectedChannel = 'general',
  bool serverSettingsOpen = false,
  bool shellTabOpen = false,
  PaneContext? rightPane,
}) =>
    channelsOnScreenOf(
      windowVisible: windowVisible,
      windowMinimized: windowMinimized,
      appBackground: appBackground,
      appLocked: appLocked,
      mobileShell: mobileShell,
      mobileRoutes: mobileRoutes,
      selectedServer: selectedServer,
      selectedChannel: selectedChannel,
      serverSettingsOpen: serverSettingsOpen,
      shellTabOpen: shellTabOpen,
      rightPane: rightPane,
    );

void main() {
  group('desktop', () {
    test('the selected channel is on screen', () {
      expect(_shown(), {_general});
    });

    test('a hidden or minimized window shows nothing', () {
      expect(_shown(windowVisible: false), isEmpty);
      expect(_shown(windowMinimized: true), isEmpty);
    });

    test('server settings, a centre tab, DMs and meetings show no channel', () {
      expect(_shown(serverSettingsOpen: true), isEmpty);
      expect(_shown(shellTabOpen: true), isEmpty);
      expect(_shown(selectedServer: null), isEmpty);
      expect(_shown(selectedServer: 'conf:abc'), isEmpty);
    });

    test('a split pane adds its own channel', () {
      expect(
        _shown(rightPane: const PaneContext(serverId: 'srv', channelId: 'art')),
        {_general, (serverId: 'srv', channelId: 'art')},
      );
      expect(
        _shown(
            rightPane: const PaneContext(
                serverId: 'srv', channelId: 'art', settingsOpen: true)),
        {_general},
      );
      expect(_shown(rightPane: const PaneContext(peerId: 'friend')), {_general});
    });

    test('a centre tab covers the split pane too', () {
      expect(
        _shown(
            shellTabOpen: true,
            rightPane: const PaneContext(serverId: 'srv', channelId: 'art')),
        isEmpty,
      );
    });

    // Settings keeps the selection underneath (`openSettings`), so only the
    // open tab says the chat is covered.
    test('Settings opened over a channel takes it off screen until it closes', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(selectedServerProvider.notifier).state = 'srv';
      c.read(selectedChannelProvider.notifier).state = 'general';
      c.read(splitViewProvider.notifier)
        ..openSplit()
        ..navigateRightToServer('srv', channelId: 'art');
      expect(c.read(channelsOnScreenProvider),
          {_general, (serverId: 'srv', channelId: 'art')});
      openSettings(c.read);
      expect(c.read(selectedChannelProvider), 'general');
      expect(c.read(channelsOnScreenProvider), isEmpty);
      for (final tab in ShellTab.values) {
        setShellTab(c.read, tab);
        expect(c.read(channelsOnScreenProvider), isEmpty, reason: '$tab');
      }
      setShellTab(c.read, null);
      expect(c.read(channelsOnScreenProvider),
          {_general, (serverId: 'srv', channelId: 'art')});
    });
  });

  group('phone shell', () {
    test('only the top chat route counts, never the desktop selection', () {
      expect(_shown(mobileShell: true), isEmpty);
      expect(
        _shown(mobileShell: true, mobileRoutes: [
          (serverId: 'srv', channelId: 'old'),
          _general,
        ]),
        {_general},
      );
    });

    test('backgrounded or locked shows nothing', () {
      expect(
          _shown(mobileShell: true, mobileRoutes: [_general], appBackground: true),
          isEmpty);
      expect(_shown(mobileShell: true, mobileRoutes: [_general], appLocked: true),
          isEmpty);
    });

    test('a meeting route is not a server channel', () {
      expect(
        _shown(
            mobileShell: true,
            mobileRoutes: [(serverId: 'conf:abc', channelId: 'chat')]),
        isEmpty,
      );
    });
  });

  group('phone pages', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          navigatorKey: nav,
          navigatorObservers: [pageRouteObserver],
          home: const _ChannelPage(),
        ),
      ));
      final c = ProviderScope.containerOf(tester.element(find.byType(_ChannelPage)));
      c.read(mobileShellActiveProvider.notifier).state = true;
      await tester.pump();
      return c;
    }

    testWidgets('a DM page pushed over a channel takes it off screen until it pops',
        (tester) async {
      final c = await pump(tester);
      expect(c.read(channelsOnScreenProvider), {_general});
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      // MobileProfileSheet's "Message" pushes a DM route over the channel.
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const Text('dm'))));
      await tester.pumpAndSettle();
      expect(c.read(channelsOnScreenProvider), isEmpty);
      nav.pop();
      await tester.pumpAndSettle();
      expect(c.read(channelsOnScreenProvider), {_general});
    });

    testWidgets('a dialog over a channel leaves it on screen', (tester) async {
      final c = await pump(tester);
      unawaited(showDialog<void>(
          context: tester.element(find.byType(_ChannelPage)),
          builder: (_) => const Text('menu')));
      await tester.pumpAndSettle();
      expect(c.read(channelsOnScreenProvider), {_general});
    });

    testWidgets('a channel page that closes leaves nothing behind', (tester) async {
      final c = await pump(tester);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(nav.push(MaterialPageRoute<void>(
          builder: (_) => const _ChannelPage(channel: 'art'))));
      await tester.pumpAndSettle();
      expect(c.read(channelsOnScreenProvider), {(serverId: 'srv', channelId: 'art')});
      nav.pop();
      await tester.pumpAndSettle();
      expect(c.read(channelsOnScreenProvider), {_general});
    });
  });

  group('handing the node the set', () {
    final api = _OnScreenApi();
    setUpAll(() => RustLib.initMock(api: api));
    setUp(api.calls.clear);

    // An async call could land after a later one and leave a channel on screen
    // that the person already left.
    test('each update reaches the node at once, in order', () {
      pushChannelsOnScreen({_general});
      pushChannelsOnScreen(const {});
      expect(api.calls, ['srv/general', '']);
    });

    test('a refused update throws nothing at the caller', () {
      api.fail = true;
      addTearDown(() => api.fail = false);
      expect(() => pushChannelsOnScreen({_general}), returnsNormally);
    });
  });

  test('routes close by their own token', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final routes = container.read(mobileChannelRoutesProvider.notifier);
    final a = Object(), b = Object();
    routes.open(a, _general);
    routes.open(b, (serverId: 'srv', channelId: 'art'));
    routes.close(a);
    expect([for (final e in container.read(mobileChannelRoutesProvider)) e.$2],
        [(serverId: 'srv', channelId: 'art')]);
  });

  group('guest view sweep', () {
    const mb = 1024 * 1024;
    bool takes({bool shown = true, int limitMb = 34, bool image = true, int size = mb}) =>
        guestSweepTakes(appOnScreen: shown, limitMb: limitMb, isImage: image, sizeBytes: size);

    test('pulls images in view within the limit', () {
      expect(takes(), isTrue);
      expect(takes(image: false), isFalse);
      expect(takes(limitMb: 0), isFalse);
      expect(takes(size: 34 * mb + 1), isFalse);
    });

    test('a hidden, minimized, backgrounded or locked app pulls nothing', () {
      expect(takes(shown: false), isFalse);
      for (final hidden in [
        appOnScreenOf(windowVisible: false, windowMinimized: false, appBackground: false, appLocked: false),
        appOnScreenOf(windowVisible: true, windowMinimized: true, appBackground: false, appLocked: false),
        appOnScreenOf(windowVisible: true, windowMinimized: false, appBackground: true, appLocked: false),
        appOnScreenOf(windowVisible: true, windowMinimized: false, appBackground: false, appLocked: true),
      ]) {
        expect(hidden, isFalse);
      }
      expect(
          appOnScreenOf(windowVisible: true, windowMinimized: false, appBackground: false, appLocked: false),
          isTrue);
    });
  });

  group('viewport sweep limit', () {
    const mb = 1024 * 1024;
    test('off pulls only voice notes', () {
      expect(sweepTakes(limitMb: 0, sizeBytes: 10, voiceNote: false), isFalse);
      expect(sweepTakes(limitMb: 0, sizeBytes: 10, voiceNote: true), isTrue);
    });

    test('a file over the limit waits for a tap', () {
      expect(sweepTakes(limitMb: 34, sizeBytes: 34 * mb, voiceNote: false), isTrue);
      expect(sweepTakes(limitMb: 34, sizeBytes: 34 * mb + 1, voiceNote: false),
          isFalse);
    });
  });
}

/// A phone chat page showing one server channel.
class _ChannelPage extends ConsumerStatefulWidget {
  const _ChannelPage({this.channel = 'general'});
  final String channel;

  @override
  ConsumerState<_ChannelPage> createState() => _ChannelPageState();
}

class _ChannelPageState extends ConsumerState<_ChannelPage>
    with ChannelOnScreenRoute<_ChannelPage> {
  @override
  ScreenChannel? get onScreenChannel =>
      (serverId: 'srv', channelId: widget.channel);

  @override
  Widget build(BuildContext context) => Text(widget.channel);
}

class _OnScreenApi implements RustLibApi {
  final calls = <String>[];
  bool fail = false;

  @override
  void crateApiNetworkSetChannelsOnScreen(
      {required List<String> serverIds, required List<String> channelIds}) {
    if (fail) throw 'server and channel lists differ in length';
    calls.add([
      for (var i = 0; i < serverIds.length; i++) '${serverIds[i]}/${channelIds[i]}'
    ].join(','));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

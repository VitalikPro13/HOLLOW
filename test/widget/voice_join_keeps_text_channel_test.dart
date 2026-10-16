// #110: joining a voice room from the desktop sidebar keeps the text channel a
// person is reading on screen, with whatever they had typed, and a draft that
// does leave the screen comes back with its conversation.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/network.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Every FFI call stays pending, so panes sit in their loading states.
class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

/// A voice provider whose join is answered the way the node answers it: our
/// own `VoiceChannelJoined` event, run through the real event handling.
class _EchoingVoice extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState();

  @override
  Future<void> joinChannel(String serverId, String channelId) async {
    ref.read(eventStreamProvider.notifier).debugDispatch(
          NetworkEvent.voiceChannelJoined(
            serverId: serverId,
            channelId: channelId,
            peerId: kLocalPeerId,
            isSelf: true,
          ),
        );
  }

  @override
  Future<void> onLocalJoined(String serverId, String channelId) async {
    state = state.copyWith(
      currentServerId: serverId,
      currentChannelId: channelId,
      currentChannelName: 'Voice',
    );
  }
}

/// The desktop centre region as the shell builds it: a text channel's chat
/// pane, keyed by channel, or the voice stage.
class _Centre extends ConsumerWidget {
  const _Centre();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(selectedChannelProvider);
    final channel = id == null ? null : testChannels[id];
    if (channel == null) return const SizedBox.shrink();
    if (channel.channelType == ChannelType.voice) {
      return const Center(child: Text('voice stage'));
    }
    return ChannelChatPane(
      key: ValueKey('ch:$id'),
      serverId: kServerId1,
      channelId: channel.channelId,
      channelName: channel.name,
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context, WidgetRef ref) => ChannelSidebar(
        peers: const {},
        lastMessages: const {},
        selectedPeerId: null,
        nodeStatus: NodeStatus.connected,
        onPeerSelected: (_) {},
        lastMessage: (_) => null,
        formatTime: (_) => '',
        selectedServer: testServers[kServerId1]!,
        channels: testChannels,
        selectedChannelId: ref.watch(selectedChannelProvider),
        onChannelSelected: (id) =>
            ref.read(selectedChannelProvider.notifier).state = id,
      );
}

Future<void> _pumpDesktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      voiceChannelProvider.overrideWith(_EchoingVoice.new),
      selectedServerProvider.overrideWith((_) => kServerId1),
      selectedChannelProvider.overrideWith((_) => kChannelId1),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const Scaffold(
        body: Row(children: [
          SizedBox(width: 240, child: _Sidebar()),
          Expanded(child: _Centre()),
        ]),
      ),
    ),
  ));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Finder get _voiceTile => find.byElementPredicate(
    (e) => e.widget.runtimeType.toString() == '_VoiceChannelTile');

Finder _composerIn(Type pane) => find
    .descendant(of: find.byType(pane), matching: find.byType(EditableText))
    .last;

String _composerText(WidgetTester tester, Type pane) =>
    tester.widget<EditableText>(_composerIn(pane)).controller.text;

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

void main() {
  setUpAll(() {
    RustLib.initMock(api: _PendingApi());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  testWidgets('joining voice from the sidebar keeps the text channel and draft',
      (tester) async {
    await _pumpDesktop(tester);
    await tester.enterText(_composerIn(ChannelChatPane), 'half a thought');
    await tester.pump();

    await tester.tap(_voiceTile);
    await _settle(tester);

    final container = _container(tester);
    expect(container.read(voiceChannelProvider).currentChannelId,
        kVoiceChannelId);
    expect(container.read(selectedChannelProvider), kChannelId1);
    expect(find.text('voice stage'), findsNothing);
    expect(_composerText(tester, ChannelChatPane), 'half a thought');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a second tap opens the stage and the draft waits for the return',
      (tester) async {
    await _pumpDesktop(tester);
    await tester.enterText(_composerIn(ChannelChatPane), 'half a thought');
    await tester.pump();
    await tester.tap(_voiceTile);
    await _settle(tester);

    // Connected: the tile now opens the room's stage.
    await tester.tap(_voiceTile);
    await _settle(tester);
    expect(find.text('voice stage'), findsOneWidget);
    expect(find.byType(ChannelChatPane), findsNothing);

    await tester.tap(find.text('general'));
    await _settle(tester);
    expect(_composerText(tester, ChannelChatPane), 'half a thought');
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a phone chat keeps its draft when the page closes and reopens',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        serverListProvider.overrideWith(() => _OneServer()),
      ]),
      child: MaterialApp(
        navigatorKey: nav,
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: Text('chats')),
      ),
    ));
    Future<void> open() async {
      unawaited(nav.currentState!.push(hollowMobileRoute<void>(
        settings: const RouteSettings(name: MobileChatRoute.routeName),
        builder: (_) => const MobileChatRoute(
          serverId: kServerId1,
          channelId: kChannelId1,
          channelName: 'general',
        ),
      )));
      await _settle(tester);
    }

    await open();
    await tester.enterText(_composerIn(MobileChatRoute), 'half a thought');
    await tester.pump();
    nav.currentState!.pop();
    await _settle(tester);
    expect(find.byType(MobileChatRoute), findsNothing);

    await open();
    expect(_composerText(tester, MobileChatRoute), 'half a thought');
    await tester.pump(const Duration(seconds: 2));
  });
}

class _OneServer extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => {kServerId1: testServers[kServerId1]!};
}

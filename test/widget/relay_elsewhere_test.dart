// HOL-SEC-211: a server that lives on another relay opens read-only (desktop
// and phone), says so in the owner's words when it is the person's own, and
// takes the composer back once it lives on this relay again.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/relay_denied_notice.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/dialogs/relay_denied_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_connection_indicator.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Every FFI call stays pending, so the pane sits in its loading state; a
/// server's channel list answers, so the phone's server row can open a room.
class _PendingApi implements RustLibApi {
  @override
  Future<List<crdt_api.ChannelFfi>> crateApiCrdtGetServerChannels(
          {required String serverId}) async =>
      const [
        crdt_api.ChannelFfi(
          channelId: kVoiceChannelId,
          name: 'Voice',
          channelType: 'voice',
          visibility: 'everyone',
          posting: 'everyone',
          isPublic: false,
          slowMode: 0,
          mediaOnly: false,
          visibilityLabels: [],
          postingLabels: [],
          meCanSee: true,
          meCanPost: true,
          chatOpen: true,
          voiceChat: 'server',
        ),
      ];

  @override
  Future<String> crateApiCrdtGetChannelLayout({required String serverId}) async =>
      '';

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

Future<ProviderContainer> _pumpChat(WidgetTester tester,
    {required bool phone, Map<String, ServerElsewhere> elsewhere = const {}}) async {
  tester.view.physicalSize = phone ? const Size(400, 800) : const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final channel = testChannels[kChannelId1]!;
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: hollowTestOverrides(extra: [
      selectedServerProvider.overrideWith((_) => kServerId1),
      selectedChannelProvider.overrideWith((_) => kChannelId1),
      relayElsewhereServersProvider.overrideWith((_) => elsewhere),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: phone
          ? MobileChatRoute(
              serverId: kServerId1,
              channelId: channel.channelId,
              channelName: channel.name,
            )
          : Scaffold(
              body: ChannelChatPane(
                serverId: kServerId1,
                channelId: channel.channelId,
                channelName: channel.name,
              ),
            ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

Finder get _composer => find.byType(EditableText);

const _home = 'home.example.org';

void main() {
  setUpAll(() {
    RustLib.initMock(api: _PendingApi());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  for (final phone in [false, true]) {
    final where = phone ? 'phone' : 'desktop';

    testWidgets('$where: a server on another relay shows where it lives',
        (tester) async {
      final container = await _pumpChat(tester, phone: phone, elsewhere: {
        kServerId1.toLowerCase(): (relay: _home, owned: false),
      });
      expect(find.text(kServerElsewhereText), findsOneWidget);
      expect(find.text(_home), findsOneWidget);
      expect(find.text('Switch relay'), findsOneWidget);
      expect(_composer, findsNothing, reason: 'nothing to type into');

      // It lives on this relay again (`ServerElsewhere` with no relay).
      container.read(relayElsewhereServersProvider.notifier).state = const {};
      await tester.pump();
      expect(find.text(kServerElsewhereText), findsNothing);
      expect(_composer, findsWidgets);
    });

    testWidgets('$where: the owner is told it is their own server',
        (tester) async {
      await _pumpChat(tester, phone: phone, elsewhere: {
        kServerId1.toLowerCase(): (relay: _home, owned: true),
      });
      expect(find.text(kOwnServerElsewhereText), findsOneWidget);
      expect(find.text(kServerElsewhereText), findsNothing);
      expect(_composer, findsNothing);
    });

    testWidgets('$where: a server on our relay keeps its composer',
        (tester) async {
      await _pumpChat(tester, phone: phone);
      expect(find.text(kServerElsewhereText), findsNothing);
      expect(_composer, findsWidgets);
    });
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/shell/conference_dashboard.dart';
import 'package:hollow/src/ui/shell/member_list.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// t14-deny: the states the first shots left out, each carried (before) and
/// refused (after): readable history above the notice, the meeting chat in its
/// panel, the pending-join row and sheet, and the members shown offline.
/// Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/relay_denied_states.
class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

const _ada = 'peer_ada_1111111111111111';
const _nova = 'peer_nova_222222222222222';
const _confId = 'abababababababababababababababababababab';

List<ChannelChatMessage> _history() {
  final now = DateTime.now();
  ChannelChatMessage m(String id, String from, String text, int minutesAgo) =>
      ChannelChatMessage(
        senderId: from,
        text: text,
        isMe: from == kLocalPeerId,
        messageId: id,
        timestamp: now.subtract(Duration(minutes: minutesAgo)),
      );
  return [
    m('h1', _ada, 'Did anyone save the map from last night?', 42),
    m('h2', _nova, 'I have it, uploading after dinner.', 40),
    m('h3', kLocalPeerId, 'Thanks. Same time on Friday?', 31),
    m('h4', _ada, 'Friday works. I will bring the new campaign notes.', 12),
    m('h5', _nova, 'Sounds good to me.', 3),
  ];
}

class _History extends ChannelChatNotifier {
  final String key;
  _History(this.key);

  @override
  Map<String, List<ChannelChatMessage>> build() => {key: _history()};
}

class _Online extends OnlineIdentitiesNotifier {
  @override
  Set<String> build() => {_ada, _nova};
}

class _Pending extends PendingJoinsNotifier {
  @override
  Map<String, PendingJoinInfo> build() => {
        kServerId2: const PendingJoinInfo(
            serverId: kServerId2,
            requestedAt: 1,
            state: PendingJoinInfo.statePending),
      };
}

class _InMeeting extends ConferenceNotifier {
  @override
  ConferenceState build() => const ConferenceState(
        roomsLoaded: true,
        activeConfId: _confId,
        lobbyStatus: ConferenceLobbyStatus.inCall,
      );

  @override
  Future<void> loadRooms() async {}
}

List<crdt_api.MemberFfi> _members() => const [
      crdt_api.MemberFfi(
          peerId: kLocalPeerId,
          displayName: 'Me',
          role: 'owner',
          nickname: '',
          twitchUsername: '',
          labels: []),
      crdt_api.MemberFfi(
          peerId: _ada,
          displayName: 'Ada',
          role: 'admin',
          nickname: '',
          twitchUsername: '',
          labels: []),
      crdt_api.MemberFfi(
          peerId: _nova,
          displayName: 'Nova',
          role: 'member',
          nickname: '',
          twitchUsername: '',
          labels: []),
      crdt_api.MemberFfi(
          peerId: 'peer_faust_33333333333333',
          displayName: 'DrFaust',
          role: 'member',
          nickname: '',
          twitchUsername: '',
          labels: []),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}relay_denied_states';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
              ? 'GeistMono'
              : null;
      if (family == null) continue;
      families
          .putIfAbsent(family, () => [])
          .add(ByteData.view(File(face.path).readAsBytesSync().buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });

  /// The whole view, overlays (sheets) included.
  Future<void> capture(WidgetTester tester, String name) async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      final image = await layer.toImage(view.paintBounds);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
    });
  }

  void size(WidgetTester tester, Size s) {
    tester.view.physicalSize = s;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Override deny(bool denied, String id) => relayDeniedServersProvider
      .overrideWith((_) => denied ? {id.toLowerCase()} : <String>{});

  Future<void> pumpApp(WidgetTester tester, List<Override> extra, Widget home) async {
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        overallConnectionProvider.overrideWithValue(OverallConnection.connected),
        ...extra,
      ]),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: home,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  for (final denied in [false, true]) {
    final tag = denied ? 'after' : 'before';
    final channel = testChannels[kChannelId1]!;
    final history = channelChatProvider
        .overrideWith(() => _History('$kServerId1:$kChannelId1'));

    testWidgets('history desktop $tag', (tester) async {
      size(tester, const Size(1280, 720));
      await pumpApp(
          tester,
          [
            selectedServerProvider.overrideWith((_) => kServerId1),
            selectedChannelProvider.overrideWith((_) => kChannelId1),
            history,
            deny(denied, kServerId1),
          ],
          Scaffold(
            body: ChannelChatPane(
              serverId: kServerId1,
              channelId: channel.channelId,
              channelName: channel.name,
            ),
          ));
      await capture(tester, 'history_desktop_$tag');
    });

    testWidgets('history phone $tag', (tester) async {
      size(tester, const Size(375, 760));
      await pumpApp(
          tester,
          [
            selectedServerProvider.overrideWith((_) => kServerId1),
            selectedChannelProvider.overrideWith((_) => kChannelId1),
            history,
            deny(denied, kServerId1),
          ],
          MobileChatRoute(
            serverId: kServerId1,
            channelId: channel.channelId,
            channelName: channel.name,
          ));
      await capture(tester, 'history_phone_$tag');
    });

    testWidgets('members $tag', (tester) async {
      size(tester, const Size(260, 420));
      await pumpApp(
          tester,
          [
            serverMembersProvider(kServerId1)
                .overrideWith((ref) async => _members()),
            onlineIdentitiesProvider.overrideWith(_Online.new),
            deny(denied, kServerId1),
          ],
          const Scaffold(body: MemberList(serverId: kServerId1)));
      await capture(tester, 'members_$tag');
    });

    testWidgets('meeting desktop $tag', (tester) async {
      size(tester, const Size(1280, 720));
      await pumpApp(
          tester,
          [
            conferenceProvider.overrideWith(_InMeeting.new),
            deny(denied, conferenceServerId(_confId)),
          ],
          const Scaffold(body: ConferenceDashboard()));
      await capture(tester, 'meeting_desktop_$tag');
    });

    testWidgets('pending join phone $tag', (tester) async {
      await pumpHollowMobile(tester,
          viewportSize: const Size(375, 760),
          extraOverrides: [
            pendingJoinsProvider.overrideWith(_Pending.new),
            deny(denied, kServerId2),
          ]);
      await capture(tester, 'pending_row_$tag');
      final row = find.text(denied ? kPendingJoinDeniedTitle : 'Join request pending');
      await tester.tap(row.first);
      await tester.pumpAndSettle();
      await capture(tester, 'pending_sheet_$tag');
    });
  }
}

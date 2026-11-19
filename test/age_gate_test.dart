// Age-restricted servers on phones (t14-agegate): every Dart surface follows the
// hidden set Rust computes, and a phone that hides them never consents to one.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_on_screen_provider.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/core/providers/gif_provider.dart';
import 'package:hollow/src/core/providers/mention_preview_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart' show debugPushTapsOnHost;
import 'package:hollow/src/ui/settings/network_section.dart';
import 'package:hollow/src/ui/settings/pages/network_page.dart';
import 'package:hollow/src/ui/settings/settings_place.dart' show settingsSearchHits;
import 'package:hollow/src/ui/settings/storage_section.dart';

import 'helpers/test_app.dart';

/// What Rust lists; every other FFI call stays pending.
class _Api implements RustLibApi {
  List<ServerFfi> servers = const [];

  @override
  Future<List<ServerFfi>> crateApiCrdtGetJoinedServers() async => servers;

  @override
  Future<List<ChannelFfi>> crateApiCrdtGetServerChannels(
          {required String serverId}) async =>
      const [];

  final shareStarts = <String?>[];

  @override
  Future<void> crateApiShareShareStartFromRef({
    required String rootHash,
    required String keyHex,
    required String saveDir,
    required bool sequential,
    String? serverId,
    String? contextType,
  }) async =>
      shareStarts.add(serverId);

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

final _api = _Api();

class _Gate extends AgeGateNotifier {
  _Gate(this.initial);
  final AgeGateState initial;

  @override
  AgeGateState build() => initial;

  @override
  Future<void> load() async {}
}

const _closed = AgeGateState(allowedHere: false, hidden: {'hidden'});
const _open = AgeGateState(allowedHere: true);

ServerFfi _server(String id, {bool nsfw = false}) => ServerFfi(
    serverId: id, name: id, memberCount: 2, channelCount: 1, isNsfw: nsfw);

ProviderContainer _container(AgeGateState gate,
    {AgeGateMode mode = AgeGateMode.phoneRemote, List<Override> extra = const []}) {
  final c = ProviderContainer(overrides: [
    ageGateModeProvider.overrideWithValue(mode),
    ageGateProvider.overrideWith(() => _Gate(gate)),
    ...extra,
  ]);
  addTearDown(c.dispose);
  return c;
}

class _RRating extends GifRatingNotifier {
  @override
  String build() => 'r';
}

void main() {
  setUpAll(() => RustLib.initMock(api: _api));

  test('a closed phone lists neither a server Rust hides nor one flagged 18+',
      () async {
    _api.servers = [_server('clean'), _server('flagged', nsfw: true)];
    final c = _container(_closed);
    await c.read(serverListProvider.notifier).loadFromDb();
    expect(c.read(serverListProvider).keys, ['clean']);

    final open = _container(_open, mode: AgeGateMode.desktop);
    await open.read(serverListProvider.notifier).loadFromDb();
    expect(open.read(serverListProvider).keys, containsAll(['clean', 'flagged']));
  });

  test('a server a sibling joined waits for Rust to list it on a closed phone',
      () async {
    _api.servers = const [];
    final c = _container(_closed);
    c.read(serverListProvider.notifier).onServerCreated('new', 'Adult');
    await Future<void>.delayed(Duration.zero);
    expect(c.read(serverListProvider), isEmpty);

    final open = _container(_open, mode: AgeGateMode.desktop);
    open.read(serverListProvider.notifier).onServerCreated('new', 'Adult');
    expect(open.read(serverListProvider).keys, ['new']);
  });

  test('a hidden server counts no unread and keeps no mention preview', () {
    final c = _container(_closed);
    final unread = c.read(unreadProvider.notifier);
    unread.onChannelMessage('hidden', 'ch', 'm1', false, isMention: true);
    expect(c.read(unreadProvider).channelUnreadCounts, isEmpty);
    unread.onChannelMessage('shown', 'ch', 'm2', false);
    expect(c.read(unreadProvider).channelUnreadCounts, {'shown:ch': 1});
    unread.dropServers({'shown'});
    expect(c.read(unreadProvider).channelUnreadCounts, isEmpty);

    final previews = c.read(mentionPreviewProvider.notifier);
    previews.record(MentionPreview(
        serverId: 'hidden', channelId: 'ch', senderId: 'x', text: 't', at: DateTime(2026)));
    previews.dropServers({'hidden'});
    expect(c.read(mentionPreviewProvider), isEmpty);
  });

  test('an iPhone with the gate closed never asks Klipy for R, DMs included', () {
    final phone = _container(_closed,
        extra: [gifRatingProvider.overrideWith(_RRating.new)]);
    expect(phone.read(gifRatingHereProvider), 'pg-13');
    final allowed = _container(const AgeGateState(allowedHere: true),
        extra: [gifRatingProvider.overrideWith(_RRating.new)]);
    expect(allowed.read(gifRatingHereProvider), 'r');
    final desktop = _container(_open,
        mode: AgeGateMode.desktop,
        extra: [gifRatingProvider.overrideWith(_RRating.new)]);
    expect(desktop.read(gifRatingHereProvider), 'r');
  });

  Future<void> pumpWith(WidgetTester tester, AgeGateMode mode,
      AgeGateState gate, Widget child, {List<Override> extra = const []}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        ageGateModeProvider.overrideWithValue(mode),
        ageGateProvider.overrideWith(() => _Gate(gate)),
        ...extra,
      ]),
      child: MaterialApp(
        navigatorKey: hollowNavigatorKey,
        theme: HollowThemeData.dark(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ));
    await tester.pump();
  }

  testWidgets('an 18+ consent ask on a closed phone shows why, never consent',
      (tester) async {
    await pumpWith(tester, AgeGateMode.phoneRemote, _closed, const SizedBox());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(SizedBox).first));
    container.read(eventStreamProvider.notifier).debugDispatch(
        const NetworkEvent.twitchJoinRejected(
            serverId: 'srv', reason: 'nsfw_confirm:Adult'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Age-restricted server'), findsOneWidget);
    expect(find.text('Sensitive content warning'), findsNothing);
    expect(find.text('Open settings'), findsNothing, reason: 'no setting on an iPhone');
  });

  testWidgets('a sideloaded Android phone points at its own setting',
      (tester) async {
    await pumpWith(tester, AgeGateMode.phoneLocal, _closed, const SizedBox());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(SizedBox).first));
    container.read(eventStreamProvider.notifier).debugDispatch(
        const NetworkEvent.twitchJoinRejected(
            serverId: 'srv', reason: 'nsfw_confirm:Adult'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.text('Sensitive content warning'), findsNothing);
  });

  testWidgets('a computer still asks for consent', (tester) async {
    await pumpWith(tester, AgeGateMode.desktop, _open, const SizedBox());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(SizedBox).first));
    container.read(eventStreamProvider.notifier).debugDispatch(
        const NetworkEvent.twitchJoinRejected(
            serverId: 'srv', reason: 'nsfw_confirm:Adult'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Sensitive content warning'), findsOneWidget);
  });

  testWidgets("a hidden server's voice room is left when the gate closes on it",
      (tester) async {
    final rooms = <String, _InRoom>{};
    for (final room in ['hidden', 'conf:meet', 'shown']) {
      await tester.pumpWidget(const SizedBox());
      await pumpWith(tester, AgeGateMode.phoneRemote,
          const AgeGateState(allowedHere: false, hidden: {'hidden', 'conf:meet'}),
          const SizedBox(),
          extra: [voiceChannelProvider.overrideWith(() => rooms[room] = _InRoom(room))]);
      final container = ProviderScope.containerOf(
          tester.element(find.byType(SizedBox).first));
      container.read(voiceChannelProvider);
      container.read(eventStreamProvider.notifier).debugDispatch(
          const NetworkEvent.ageGateChanged(allowed: false));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(rooms['hidden']!.leaves, 1, reason: 'its audio and video would keep playing');
    expect(rooms['conf:meet']!.leaves, 0, reason: 'a meeting is never left this way');
    expect(rooms['shown']!.leaves, 0, reason: 'control');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the storage page names no hidden server', (tester) async {
    BigInt b(int n) => BigInt.from(n);
    final usage = storage_api.StorageBreakdown(
      totalDbBytes: b(2048),
      totalDiskBytes: b(2048),
      vaultCacheBytes: BigInt.zero,
      vaultShardBytes: BigInt.zero,
      assetBlobBytes: BigInt.zero,
      assetBlobCount: 0,
      serverMessageCount: 0,
      contexts: [
        for (final sid in ['hiddensv', 'shownsrv'])
          storage_api.StorageContextUsage(
              contextType: 'channel', contextId: '$sid:general', bytesDb: b(1024), fileCount: 1),
      ],
    );
    await pumpWith(tester, AgeGateMode.phoneRemote,
        const AgeGateState(allowedHere: false, hidden: {'hiddensv'}),
        const StorageBreakdownView(),
        extra: [storageBreakdownProvider.overrideWith((ref) async => usage)]);
    await tester.pump();
    await tester.tap(find.text('Show'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('shownsrv'), findsOneWidget, reason: 'control');
    expect(find.textContaining('hiddensv'), findsNothing);
  });

  test("an iPhone's settings search has no age-restricted entry", () {
    bool lists(AgeGateMode mode) =>
        settingsSearchHits('adult', mode).any((e) => e.label == 'Age-restricted servers');
    expect(lists(AgeGateMode.phoneRemote), isFalse);
    expect(lists(AgeGateMode.phoneLocal), isTrue);
    expect(lists(AgeGateMode.desktop), isTrue);
  });

  testWidgets("a hidden server's media is never pulled on its own", (tester) async {
    // Both channels on screen: only the age gate may hold the hidden one back.
    await pumpWith(tester, AgeGateMode.phoneRemote, _closed, const SizedBox(),
        extra: [
          channelsOnScreenProvider.overrideWithValue({
            (serverId: 'hidden', channelId: 'ch'),
            (serverId: 'shown', channelId: 'ch'),
          }),
        ]);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(SizedBox).first));
    final events = container.read(eventStreamProvider.notifier);
    _api.shareStarts.clear();
    for (final sid in ['hidden', 'shown']) {
      events.debugDispatch(
          NetworkEvent.messageSyncCompleted(serverId: sid, newMessageCount: 0));
      events.debugDispatch(NetworkEvent.fileHeaderReceived(
          fileId: 'f-$sid',
          fileName: 'photo.webp',
          sizeBytes: BigInt.from(1024),
          isImage: true,
          messageId: 'm-$sid',
          senderId: 'poster',
          serverId: sid,
          channelId: 'ch',
          shareRootHash: 'ab' * 32,
          shareKeyHex: 'cd' * 16));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_api.shareStarts, ['shown'], reason: 'control: a shown server pulls its small file');
  });

  testWidgets('a hidden server posts no unread from a live message',
      (tester) async {
    await pumpWith(tester, AgeGateMode.phoneRemote, _closed, const SizedBox());
    final container = ProviderScope.containerOf(
        tester.element(find.byType(SizedBox).first));
    container.read(eventStreamProvider.notifier).debugDispatch(
        const NetworkEvent.channelMessageReceived(
            serverId: 'hidden',
            channelId: 'ch',
            fromPeer: 'someone',
            text: '@everyone hi',
            timestamp: 1,
            messageId: 'm1',
            replyToMid: '',
            replyToOwn: false,
            duplicate: false,
            isOwn: false));
    await tester.pump();
    expect(container.read(unreadProvider).channelUnreadCounts, isEmpty);
    expect(container.read(mentionPreviewProvider), isEmpty);
  });

  testWidgets('Settings: the computer row, the Android toggle, nothing on iPhone',
      (tester) async {
    await pumpWith(tester, AgeGateMode.phoneRemote, _closed,
        const AgeRestrictedSection());
    expect(find.text('Age-restricted servers'), findsNothing);

    await pumpWith(tester, AgeGateMode.phoneLocal, _closed,
        const AgeRestrictedSection());
    expect(find.text('Allow age-restricted servers'), findsOneWidget);

    await pumpWith(tester, AgeGateMode.desktop, _open,
        const AgeRestrictedSection());
    expect(find.text('Allow age-restricted servers on my phones'), findsOneWidget);
    await tester.tap(find.byType(HollowToggle));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Allow on your phones?'), findsOneWidget,
        reason: 'turning it on asks first');
  });

  testWidgets("an iPhone's Network page has no empty age-restricted slot",
      (tester) async {
    await pumpWith(tester, AgeGateMode.phoneRemote, _closed,
        const NetworkSettingsPage());
    expect(find.byType(AgeRestrictedSection), findsNothing,
        reason: 'an empty child still gets a divider on each side');

    await pumpWith(tester, AgeGateMode.desktop, _open,
        const NetworkSettingsPage());
    expect(find.byType(AgeRestrictedSection), findsOneWidget,
        reason: 'control: a computer keeps it');
  });

  testWidgets('a banner tap never opens a hidden server', (tester) async {
    debugPushTapsOnHost = true;
    addTearDown(() => debugPushTapsOnHost = false);
    await pumpHollowMobile(tester, extraOverrides: [
      ageGateModeProvider.overrideWithValue(AgeGateMode.phoneRemote),
      ageGateProvider.overrideWith(
          () => _Gate(const AgeGateState(allowedHere: false, hidden: {'hidden'}))),
    ]);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    PushNotificationService.debugDeliverOpenChannel('hidden', 'ch');
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(selectedServerProvider), isNull);
    PushNotificationService.debugDeliverOpenChannel('shown', 'ch');
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(selectedServerProvider), 'shown', reason: 'control');
  });

  testWidgets("a banner tap before Dart read the gate asks Rust", (tester) async {
    debugPushTapsOnHost = true;
    debugServerAgeHiddenNow = (sid) async => sid == 'hidden';
    addTearDown(() {
      debugPushTapsOnHost = false;
      debugServerAgeHiddenNow = null;
    });
    await pumpHollowMobile(tester, extraOverrides: [
      ageGateModeProvider.overrideWithValue(AgeGateMode.phoneRemote),
      ageGateProvider.overrideWith(() => _Gate(const AgeGateState(allowedHere: false))),
    ]);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    PushNotificationService.debugDeliverOpenChannel('hidden', 'ch');
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(selectedServerProvider), isNull);
    PushNotificationService.debugDeliverOpenChannel('shown', 'ch');
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(selectedServerProvider), 'shown', reason: 'control');
  });

  test('no banner names a hidden server or one a closed phone does not list',
      () async {
    final sink = _Sink();
    final c = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        ageGateModeProvider.overrideWithValue(AgeGateMode.phoneRemote),
        ageGateProvider.overrideWith(() => _Gate(_closed)),
        osNotificationSinkProvider.overrideWithValue(sink),
        identityProtectionProvider.overrideWith((ref) async =>
            const identity_api.ProtectionStatus(
                isEncrypted: false,
                hasPassword: false,
                hasOsKeychain: false,
                osKeychainAvailable: false)),
        serverListProvider.overrideWith(_Listed.new),
      ]),
    );
    addTearDown(c.dispose);
    await c.read(identityProtectionProvider.future);
    c.read(appLifecycleProvider.notifier).state = AppLifecycleState.paused;
    final notify = c.read(systemNotificationProvider.notifier);
    for (final sid in ['hidden', 'unlisted', 'shown']) {
      await notify.notifyChannel(
          serverId: sid, channelId: 'ch', fromPeerId: 'p', text: 'hi', isMention: true);
    }
    expect(sink.servers, ['shown']);
  });
  test('an open phone back from away lists no flagged server until the relay is back',
      () async {
    _api.servers = [_server('clean'), _server('flagged', nsfw: true)];
    final c = _container(_open);
    final list = c.read(serverListProvider.notifier);
    await list.loadFromDb();
    expect(c.read(serverListProvider).keys, containsAll(['clean', 'flagged']));

    c.read(ageGateProvider.notifier).hold();
    expect(c.read(serverListProvider).keys, ['clean'],
        reason: 'gone before the next frame, no database read');
    list.onServerCreated('new', 'Adult');
    expect(c.read(serverListProvider).keys, ['clean'],
        reason: 'a join seen while held waits for Rust');

    c.read(ageGateProvider.notifier).release();
    await Future<void>.delayed(Duration.zero);
    expect(c.read(serverListProvider).keys, containsAll(['clean', 'flagged']));

    final desk = _container(_open, mode: AgeGateMode.desktop);
    desk.read(ageGateProvider.notifier).hold();
    expect(desk.read(ageGateProvider).held, isFalse, reason: 'a computer never holds');
  });
  test('a phone held in the background still names an 18+ server it allows',
      () async {
    _api.servers = [_server('flagged', nsfw: true)];
    final sink = _Sink();
    final c = _container(_open, extra: [
      osNotificationSinkProvider.overrideWithValue(sink),
      identityProtectionProvider.overrideWith((ref) async =>
          const identity_api.ProtectionStatus(
              isEncrypted: false,
              hasPassword: false,
              hasOsKeychain: false,
              osKeychainAvailable: false)),
    ]);
    await c.read(identityProtectionProvider.future);
    await c.read(serverListProvider.notifier).loadFromDb();
    c.read(ageGateProvider.notifier).hold();
    c.read(appLifecycleProvider.notifier).state = AppLifecycleState.paused;
    expect(c.read(serverListProvider).keys, isEmpty, reason: 'setup: held off the list');
    await c.read(systemNotificationProvider.notifier).notifyChannel(
        // A mention: a server never set notifies mentions only (0.14.1).
        serverId: 'flagged', channelId: 'ch', fromPeerId: 'p', text: 'hi', isMention: true);
    expect(sink.names, ['flagged'],
        reason: 'the hold is about the screen, a live wake still names the server');

    final hidden = _container(_closed);
    await hidden.read(serverListProvider.notifier).loadFromDb();
    expect(hidden.read(serverListProvider.notifier).nameOf('flagged'), isNull,
        reason: 'a server the gate hides is never named');
  });
  test('a channel wake of an 18+ server with nothing read shows no banner', () {
    bool shows({bool posted = false, bool adult = false, String level = 'all'}) =>
        channelWakeShowsFallback(
            posted: posted, ageRestricted: adult, notifLevel: level);
    expect(shows(), isTrue, reason: 'an unread wake of a normal server');
    expect(shows(adult: true), isFalse,
        reason: 'an unread 18+ wake named its server');
    expect(shows(posted: true), isFalse);
    expect(shows(level: 'mentions'), isFalse);
  });
}

class _Sink extends OsNotificationSink {
  final servers = <String>[];
  final names = <String>[];

  @override
  bool get isMobile => true;

  @override
  dynamic noSuchMethod(Invocation invocation) async =>
      servers.add('other:${invocation.memberName}');

  @override
  Future<void> mobileChannel({
    required String serverId,
    required String channelId,
    required String serverName,
    required String channelName,
    required String senderName,
    required String messageId,
    required String text,
  }) async {
    servers.add(serverId);
    names.add(serverName);
  }
}

class _InRoom extends VoiceChannelNotifier {
  _InRoom(this.serverId);
  final String serverId;
  int leaves = 0;

  @override
  VoiceChannelState build() =>
      VoiceChannelState(currentServerId: serverId, currentChannelId: 'vc');

  @override
  Future<void> leaveChannel() async {
    leaves++;
    state = const VoiceChannelState();
  }
}

class _Listed extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => const {
        'shown': ServerInfo(serverId: 'shown', name: 'S', memberCount: 2, channelCount: 1),
        'hidden': ServerInfo(serverId: 'hidden', name: 'H', memberCount: 2, channelCount: 1),
      };
}

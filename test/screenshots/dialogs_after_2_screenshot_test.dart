import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/friends_manager_dialog.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';
import 'package:hollow/src/ui/dialogs/twitch_join_dialog.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_screen_share_sheet.dart';
import 'package:hollow/src/ui/mobile/mobile_storage_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Dialogs pass, agent 2: after renders of the dialogs this pass changed, at
/// desktop 1440x900 and phone 390x844, dark. All content is invented.
///
/// Output: $HOLLOW_SHOT_DIR/dialogs_after/2, else
/// build/ui_screenshots/dialogs_after/2.
const _desktop = Size(1440, 900);
const _phone = Size(390, 844);
const _sid = 'srv_after_2';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('shot');
  final sep = Platform.pathSeparator;
  final outDir = '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${sep}build${sep}ui_screenshots'}'
      '${sep}dialogs_after${sep}2';
  late Directory dataRoot;

  setUpAll(() async {
    RustLib.initMock(api: _Api());
    dataRoot = Directory.systemTemp.createTempSync('hollow_after_2');
    overrideHollowDataDir(dataRoot.path);
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    try {
      final material = rootBundle.load('fonts/MaterialIcons-Regular.otf');
      await (FontLoader('MaterialIcons')..addFont(material)).load();
    } catch (_) {/* the filled star falls back to a box */}
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
              ? 'GeistMono'
              : name.startsWith('SimpleIcons')
                  ? 'SimpleIcons'
                  : null;
      if (family == null) continue;
      final bytes = File(face.path).readAsBytesSync();
      families.putIfAbsent(family, () => []).add(ByteData.view(bytes.buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });
  tearDownAll(() => dataRoot.deleteSync(recursive: true));

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
    });
  }

  Future<void> settle(WidgetTester tester, {int rounds = 4}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;

  Future<void> pumpHost(WidgetTester tester, Size size,
      {List<Override> extra = const [], Widget? home}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        profileProvider.overrideWith(_Profiles.new),
        ...extra,
      ]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: home ??
              Scaffold(body: Builder(builder: (context) {
                host = context;
                return const SizedBox.expand();
              })),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> done(WidgetTester tester) async {
    // Unmounts every dialog, so no countdown or spinner outlives the test.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  for (final (label, size) in [('desktop', _desktop), ('phone', _phone)]) {
    // ------------------------------------------------------------ Twitch
    testWidgets('twitch $label', (t) async {
      await pumpHost(t, size,
          extra: [twitchJoinCallsProvider.overrideWithValue(_Twitch())]);
      showTwitchJoinDialog(host,
          serverId: _sid,
          channelId: 'c1',
          channelName: 'nightowl',
          serverName: 'Night Owls',
          minFollowDays: 30,
          requireSub: true);
      await settle(t);
      await capture(t, 'twitch_1_requirements_$label');
      await t.tap(find.text('Connect Twitch'));
      await settle(t);
      await capture(t, 'twitch_2_code_$label');
      await done(t);

      await pumpHost(t, size,
          extra: [twitchJoinCallsProvider.overrideWithValue(_Twitch())]);
      showTwitchJoinDialog(host,
          serverId: _sid,
          channelId: 'c1',
          channelName: 'nightowl',
          serverName: 'Night Owls',
          minFollowDays: 30,
          requireSub: false,
          failureReason:
              'You have followed nightowl for 12 days. This server asks for 30.');
      await settle(t);
      await capture(t, 'twitch_3_failed_$label');
      await done(t);

      await pumpHost(t, size);
      showJoinRejectedDialog(host,
          title: 'Server is full',
          message: '“Night Owls” has reached its member limit (50 members).');
      await settle(t);
      await capture(t, 'join_rejected_$label');
      await done(t);

      await pumpHost(t, size);
      unawaited(showNsfwConfirmDialog(host,
          serverName: 'Late Night Cinema', onProceed: () async {}));
      await settle(t);
      await capture(t, 'nsfw_confirm_$label');
      await done(t);
    });

    // ------------------------------------------------------- Device link
    testWidgets('device link $label', (t) async {
      Future<void> shoot(String name, DeviceLinkState s, DeviceLinkMode mode,
          {Future<void> Function()? then}) async {
        await pumpHost(t, size, extra: [
          deviceLinkSyncProvider.overrideWith(() => _Link(s)),
          overallConnectionProvider
              .overrideWithValue(OverallConnection.connected),
        ]);
        unawaited(showDeviceLinkDialog(host, mode: mode));
        await settle(t);
        if (then != null) await then();
        await capture(t, '${name}_$label');
        await done(t);
      }

      await shoot(
          'link_1_showcode',
          const DeviceLinkState(phase: LinkPhase.showingCode, code: 'K7MPQ3'),
          DeviceLinkMode.showCode);
      await shoot('link_2_entercode_short', const DeviceLinkState(),
          DeviceLinkMode.enterCode, then: () async {
        await t.enterText(find.byType(TextField), 'K7M');
        await t.tap(find.text('Link'));
        await settle(t, rounds: 2);
      });
      await shoot(
          'link_3_confirm',
          const DeviceLinkState(phase: LinkPhase.confirmPush, peerId: 'dev2'),
          DeviceLinkMode.showCode);
      await shoot(
          'link_4_receiving',
          const DeviceLinkState(
              phase: LinkPhase.receiving,
              bytesReceived: 38 * 1024 * 1024,
              totalBytes: 96 * 1024 * 1024),
          DeviceLinkMode.enterCode);
      await shoot(
          'link_5_failed',
          const DeviceLinkState(
              phase: LinkPhase.failed,
              error: "Hollow couldn't send your data. Check that both devices "
                  'are online and try again.'),
          DeviceLinkMode.showCode);
    });

    // ------------------------------------------------------ Verify contact
    testWidgets('verify contact $label', (t) async {
      if (size == _phone) {
        await pumpHost(t, size,
            home: const MobileVerifyContactRoute(peerId: kFriendPeerId1));
      } else {
        await pumpHost(t, size);
        unawaited(showVerifyContactDialog(host, peerId: kFriendPeerId1));
      }
      await settle(t);
      await capture(t, 'verify_1_$label');
      await t.enterText(find.byType(TextField), '12345 67890');
      await settle(t, rounds: 2);
      await capture(t, 'verify_2_mismatch_$label');
      await done(t);
    });

    // -------------------------------------------------------- Screen share
    testWidgets('screen share $label', (t) async {
      if (size == _phone) {
        await pumpHost(t, size);
        unawaited(showMobileScreenShareSheet(host));
        await settle(t);
        await capture(t, 'share_phone_sheet');
        await done(t);
        return;
      }
      await pumpHost(t, size);
      showHollowDialog(
          context: host,
          builder: (_) => ScreenShareDialog(sources: _Sources(_Capturer())));
      await settle(t);
      await capture(t, 'share_1_screens_$label');
      await t.tap(find.text('Windows'));
      await settle(t, rounds: 2);
      await capture(t, 'share_2_windows_$label');
      await done(t);

      await pumpHost(t, size);
      showHollowDialog(
          context: host,
          builder: (_) =>
              ScreenShareDialog(sources: _Sources(_Capturer(fail: true))));
      await settle(t);
      await capture(t, 'share_3_failed_$label');
      await done(t);
    });

    // ----------------------------------------------------- Friends manager
    testWidgets('friends manager $label', (t) async {
      await pumpHost(t, size, extra: [
        favouriteFriendsProvider.overrideWith(() => _Favourites()),
      ]);
      for (final tab in FriendsManagerTab.values) {
        showFriendsManager(host, tab: tab);
        await settle(t);
        await capture(t, 'friends_${tab.name}_$label');
        Navigator.of(host).pop();
        await settle(t, rounds: 2);
      }
      await done(t);
    });

    // ------------------------------------------------ Storage (phone route)
    testWidgets('storage $label', (t) async {
      for (final members in [3, 7]) {
        await pumpHost(t, size,
            extra: [
              vaultStatusProvider.overrideWith(_Vault.new),
              myRoleProvider(_sid).overrideWith((ref) async => 'owner'),
              serverMembersProvider(_sid).overrideWith((ref) async => [
                    for (var i = 0; i < members; i++)
                      crdt_api.MemberFfi(
                        peerId: 'peer_$i',
                        displayName: 'Member $i',
                        role: i == 0 ? 'owner' : 'member',
                        nickname: '',
                        twitchUsername: '',
                        labels: const [],
                      ),
                  ]),
            ],
            home: const MobileStorageRoute(serverId: _sid));
        await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)));
        await settle(t);
        await capture(t, 'storage_route_${members}members_$label');
        if (members == 7) {
          await t.tap(find.textContaining('Pledge:'));
          await settle(t);
          await t.enterText(find.byType(TextField).last, '100');
          await t.tap(find.text('Save'));
          await settle(t);
          await capture(t, 'storage_pledge_too_small_$label');
        }
        await done(t);
      }
    });
  }
}

// ---------------------------------------------------------------- fakes

storage_api.UserProfile _profile(String id, String name, String status) =>
    storage_api.UserProfile(
      peerId: id,
      displayName: name,
      status: status,
      aboutMe: '',
      updatedAt: 0,
      twitchUsername: '',
      showcaseBoard: '',
      avatarFrame: '',
      avatarAnim: '',
      bannerAnim: '',
      supportCreds: '',
    );

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        kFriendPeerId1: _profile(kFriendPeerId1, 'Mira', 'Painting tonight'),
        kFriendPeerId2: _profile(kFriendPeerId2, 'Juno', ''),
        kFriendPeerId3: _profile(kFriendPeerId3, 'Sam', ''),
      };
}

class _Favourites extends FavouriteFriendsNotifier {
  @override
  List<String> build() => [kFriendPeerId2];
}

class _Vault extends VaultStatusNotifier {
  @override
  Map<String, VaultServerStatus> build() => const {};
}

class _Link extends DeviceLinkSyncNotifier {
  _Link(this.seed);
  final DeviceLinkState seed;
  @override
  DeviceLinkState build() => seed;
  @override
  Future<void> enterCode(String code,
      {required bool includeVault, required bool includeFiles}) async {}
}

class _Twitch extends TwitchJoinCalls {
  @override
  Future<bool> isConnected() async => false;
  @override
  Future<twitch_api.TwitchDeviceFlowResult> startDeviceFlow() async =>
      twitch_api.TwitchDeviceFlowResult(
        userCode: 'WDJB-MJHT',
        verificationUri: 'https://www.twitch.tv/activate',
        deviceCode: 'dev',
        intervalSecs: BigInt.from(5),
      );
  @override
  Future<void> pollForToken(String deviceCode, int intervalSecs) =>
      Completer<void>().future;
}

class _Source extends DesktopCapturerSource {
  _Source(this.id, this.name, this.type);
  @override
  final String id;
  @override
  final String name;
  @override
  final SourceType type;
  @override
  Uint8List? get thumbnail => null;
  @override
  ThumbnailSize get thumbnailSize => ThumbnailSize(320, 180);
}

class _Capturer extends DesktopCapturer {
  _Capturer({this.fail = false});
  final bool fail;
  final _added = StreamController<DesktopCapturerSource>.broadcast();
  final _removed = StreamController<DesktopCapturerSource>.broadcast();
  final _thumbs = StreamController<DesktopCapturerSource>.broadcast();
  @override
  StreamController<DesktopCapturerSource> get onAdded => _added;
  @override
  StreamController<DesktopCapturerSource> get onRemoved => _removed;
  @override
  StreamController<DesktopCapturerSource> get onThumbnailChanged => _thumbs;
  @override
  Future<List<DesktopCapturerSource>> getSources(
      {required List<SourceType> types, ThumbnailSize? thumbnailSize}) async {
    if (fail) throw Exception('enumeration failed');
    return [
      _Source('0', 'Screen 1', SourceType.Screen),
      _Source('1', 'Screen 2', SourceType.Screen),
      _Source('101', 'Notes', SourceType.Window),
      _Source('102', 'Sketchbook', SourceType.Window),
      _Source('103', 'Music', SourceType.Window),
    ];
  }

  @override
  Future<bool> updateSources({required List<SourceType> types}) async => true;
}

class _Sources extends ScreenShareSources {
  _Sources(this.capturer);
  @override
  final DesktopCapturer capturer;
}

final _gib = BigInt.from(1024 * 1024 * 1024);

class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      null;

  @override
  Future<String> crateApiVerificationSafetyNumberWith(
          {required String peerId}) async =>
      '052811639472018465520937715046389120475663308217495036128874';

  @override
  String crateApiVerificationFormatSafetyNumber({required String number}) => [
        for (var i = 0; i < number.length; i += 5) number.substring(i, i + 5)
      ].join(' ');

  @override
  bool crateApiVerificationSafetyNumbersMatch(
          {required String expected, required String provided}) =>
      expected == provided.replaceAll(RegExp(r'\D'), '');

  @override
  Future<crdt_api.StorageStatsFfi> crateApiCrdtGetStorageStats(
          {required String serverId}) async =>
      crdt_api.StorageStatsFfi(
        totalPledgedBytes: _gib * BigInt.from(40),
        totalUsedBytes: _gib * BigInt.from(6),
        myPledgeBytes: _gib * BigInt.from(4),
        myUsedBytes: _gib,
        memberCount: 7,
        minPledgeMb: BigInt.from(512),
      );

  @override
  Future<String> crateApiCrdtGetServerSetting(
          {required String serverId, required String key}) async =>
      key == 'retention_files' ? '90d' : '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

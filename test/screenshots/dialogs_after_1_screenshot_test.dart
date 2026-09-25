import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/dialogs/avatar_frame_picker.dart';
import 'package:hollow/src/ui/dialogs/changelog_dialog.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/dialogs/export_archive_dialog.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/new_message_dialog.dart';
import 'package:hollow/src/ui/dialogs/news_post_dialog.dart';
import 'package:hollow/src/ui/dialogs/no_turn_dialog.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/dialogs/shard_bundle_dialog.dart';
import 'package:hollow/src/ui/dialogs/twitch_device_code_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_image_crop_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// After-renders of dialogs pass batch 1: every dialog in the batch at desktop
/// 1440x900 and phone 390x844, dark. Content is invented; FFI is mocked.
///
/// Output: $HOLLOW_SHOT_DIR/dialogs_after/1, else
/// build/ui_screenshots/dialogs_after/1.
class _Api implements RustLibApi {
  Object? proofError;

  @override
  Future<network_api.MessageProofV2> crateApiNetworkVerifyMessageProofV2({
    required String msgType,
    required String context,
    required String senderPeerId,
    required String messageId,
  }) async {
    if (proofError != null) throw proofError!;
    return network_api.MessageProofV2(
      hasSignature: true,
      valid: true,
      sigVersion: 2,
      canonicalPayload: 'hollow-msg2:dm:x',
      text: 'See you at eight',
      timestampMs: 1758800000000,
      signatureB64: 'c2ln',
      publicKeyB64: 'a2V5',
    );
  }

  @override
  Future<String> crateApiCrdtInitiateRecoveryPool(
          {required String serverId}) async =>
      'hollow://recovery?server=srv1&token=4f1c9a02b7e3d6c8a5f0e1d2c3b4a596';

  @override
  Future<twitch_api.TwitchDeviceFlowResult>
      crateApiTwitchTwitchStartDeviceFlow() async =>
          twitch_api.TwitchDeviceFlowResult(
            userCode: 'KQWT-XBRM',
            verificationUri: 'https://www.twitch.tv/activate',
            deviceCode: 'dc',
            intervalSecs: BigInt.from(5),
          );

  @override
  Future<String> crateApiTwitchTwitchPollForToken({
    required String deviceCode,
    required BigInt intervalSecs,
  }) =>
      Completer<String>().future;

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      null;

  @override
  Future<Uint8List?> crateApiStorageGetBanner({required String peerId}) async =>
      null;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() =>
      const {'srv1': ServerInfo(serverId: 'srv1', name: 'Night Owls')};
}

storage_api.UserProfile _profile(String peer, String name, String status) =>
    storage_api.UserProfile(
      peerId: peer,
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
        kFriendPeerId1: _profile(kFriendPeerId1, 'Mira', 'Painting frames'),
        kFriendPeerId2: _profile(kFriendPeerId2, 'Juno', ''),
        kFriendPeerId3: _profile(kFriendPeerId3, 'Sam', ''),
      };
}

class _OtherRelay extends RelayDomainNotifier {
  @override
  String build() => 'relay.bookclub.net';
}

class _NoTurn extends RelayStatusNotifier {
  @override
  RelayStatus build() => const RelayStatus(turn: false);
}

class _AlwaysRelay extends AlwaysRelayCallsNotifier {
  @override
  bool build() => true;
}

const _desktop = Size(1440, 900);
const _phone = Size(390, 844);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${sep}build${sep}ui_screenshots'}'
      '${sep}dialogs_after${sep}1';

  final api = _Api();
  late Uint8List photo;

  setUpAll(() async {
    RustLib.initMock(api: api);
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

    // A banded picture, so the crop's frame and shade read.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const w = 1200.0, h = 800.0;
    for (var i = 0; i < 8; i++) {
      canvas.drawRect(
        Rect.fromLTWH(i * w / 8, 0, w / 8, h),
        Paint()
          ..color = HSVColor.fromAHSV(1, i * 40.0, 0.5, 0.8).toColor(),
      );
    }
    canvas.drawCircle(
        const Offset(w / 2, h / 2), 220, Paint()..color = const Color(0xFFF1F3F5));
    final image = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    photo = data!.buffer.asUint8List();
  });

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

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;
  late WidgetRef hostRef;

  Future<void> pumpHost(WidgetTester tester, Size size,
      {List<Override> extra = const []}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: hollowTestOverrides(extra: [
          serverListProvider.overrideWith(_Servers.new),
          profileProvider.overrideWith(_Profiles.new),
          ...extra,
        ]),
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Consumer(builder: (context, ref, _) {
                host = context;
                hostRef = ref;
                return const SizedBox.expand();
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Shoots [open] at both sizes as `<name>_desktop` and `<name>_phone`.
  void shoot(
    String name,
    FutureOr<void> Function(WidgetTester tester) open, {
    List<Override> extra = const [],
    FutureOr<void> Function(WidgetTester tester)? then,
  }) {
    for (final (label, size) in [('desktop', _desktop), ('phone', _phone)]) {
      testWidgets('$name $label', (tester) async {
        await pumpHost(tester, size, extra: extra);
        // Never awaited: most helpers resolve only when their dialog closes.
        unawaited(Future.sync(() => open(tester)));
        await tester.pump();
        await settle(tester);
        if (then != null) {
          await then(tester);
          await settle(tester);
        }
        await capture(tester, '${name}_$label');
      });
    }
  }

  const proof = MessageProofData(
    senderPeerId: kFriendPeerId1,
    senderDisplayName: 'Mira',
    text: 'See you at eight, I will bring the projector.',
    timestampMs: 1758800000000,
    signature:
        'm2VhcmVzaWduYXR1cmVieXRlc2Zvcm1pcmFzbWVzc2FnZWluYmFzZTY0aGVyZTEyMw==',
    publicKey: 'CAESIG1pcmFtaXJhbWlyYW1pcmFtaXJhbWlyYW1pcmFtaXI=',
    messageId: '6f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0',
    context: 'peer',
    msgType: 'dm',
  );

  shoot('no_turn', (t) => ensureTurnForCall(host, hostRef), extra: [
    relayStatusProvider.overrideWith(_NoTurn.new),
    alwaysRelayCallsProvider.overrideWith(_AlwaysRelay.new),
  ]);
  shoot(
      'news_post',
      (t) => showNewsPostDialog(
          host,
          const NewsPost(
            id: 'n1',
            date: 'September 10, 2026',
            title: 'v0.12 is out',
            body: 'Calls hold through a bad connection now, and dialogs '
                'keep what you typed when something fails.\n\n## What changed\n'
                '- Recovery pools speak plainly\n- Proofs say when a message '
                "isn't on this device\n\nThe [changelog](https://example.org) "
                'has the rest.',
          )));
  shoot(
      'changelog',
      (t) => showChangelogDialog(host, const [
            ChangelogRelease(
              version: '0.12.0',
              title: 'Dialogs that finish what they start',
              notes: ['A calmer release, mostly polish.'],
              sections: [
                ChangelogSection(name: 'Changed', items: [
                  'Creating a channel or a server now waits for Hollow to '
                      'confirm before the dialog closes.',
                  'A message proof no longer calls a message invalid when it '
                      'simply is not on this device.',
                ]),
                ChangelogSection(name: 'Fixed', items: [
                  'The Twitch sign-in offers a retry after a failure.',
                ]),
              ],
            ),
            ChangelogRelease(
                version: '0.11.2', title: 'Older', notes: [], sections: []),
          ], 0));
  shoot(
      'mnemonic',
      (t) => showMnemonicDialog(
          host,
          'orbit velvet canyon ladder pepper noble frost cable mirror anchor '
          'lunar spice garden humble token civic ripple ozone thunder amber '
          'silk harbor quiet zebra'));
  shoot('invite',
      (t) => showInviteDialog(host, 'https://hollow.chat/join#server=srv1&relay=relay.anonlisten.com', 'srv1'));
  shoot('create_channel', (t) => showCreateChannelDialog(host, 'srv1'));
  shoot('create_server', (t) => showCreateServerDialog(host));
  shoot('license_key', (t) => showLicenseKeyDialog(host),
      extra: [relayDomainProvider.overrideWith(_OtherRelay.new)]);
  shoot('license_key_error', (t) async {
    unawaited(showLicenseKeyDialog(host,
        error: "The relay didn't accept that access key. Check it and try "
            'again.'));
  }, extra: [relayDomainProvider.overrideWith(_OtherRelay.new)]);
  shoot(
      'relay_switch',
      (t) => ensureRelayForInvite(host, hostRef,
          classifyHollowLink('hollow://join?server=abc123&relay=relay.bookclub.net')!));
  shoot('report_user', (t) async {
    unawaited(showReportUserDialog(host, masterId: 'm1', displayName: 'Juno'));
  }, then: (t) async {
    await t.tap(find.text('Spam'));
  });
  shoot('new_message', (t) => showNewMessageDialog(host));
  shoot('twitch_code', (t) => showTwitchDeviceCodeDialog(host));
  shoot(
      'export_archive',
      (t) => showExportArchiveDialog(host,
          isDm: true, peerId: kFriendPeerId1, name: 'Mira', messageCount: 1204));
  shoot(
      'avatar_frame',
      (t) => showAvatarFramePicker(
          context: host, peerId: kFriendPeerId1, currentId: 'b:168'));
  shoot(
      'recovery_start',
      (t) => showInitiateRecoveryPoolDialog(host,
          serverId: 'srv1', serverName: 'Night Owls'));
  shoot(
      'recovery_started',
      (t) => showInitiateRecoveryPoolDialog(host,
          serverId: 'srv1', serverName: 'Night Owls'),
      then: (t) => t.tap(find.text('Start pool')));
  shoot('recovery_join', (t) => showJoinRecoveryPoolDialog(host),
      then: (t) async {
    await t.enterText(find.byType(TextField), 'hello');
    await t.testTextInput.receiveAction(TextInputAction.done);
  });
  shoot(
      'shards_export',
      (t) => showExportShardsDialog(host,
          serverId: 'srv1', serverName: 'Night Owls', shardCount: 38));
  shoot('shards_import', (t) => showImportShardsDialog(host));
  shoot('proof_verified', (t) {
    api.proofError = null;
    showMessageProofDialog(host, proof);
  });
  shoot('proof_not_here', (t) {
    api.proofError = 'Message not found';
    showMessageProofDialog(host, proof);
  });
  shoot('image_crop', (t) async {
    final size = t.view.physicalSize;
    if (size.width < 600) {
      unawaited(showMobileImageCrop(
          context: host,
          imageBytes: photo,
          aspectRatio: 2.5,
          title: 'Crop banner'));
    } else {
      unawaited(showImageCropDialog(
          context: host,
          imageBytes: photo,
          aspectRatio: 2.5,
          title: 'Crop banner'));
    }
  });
}

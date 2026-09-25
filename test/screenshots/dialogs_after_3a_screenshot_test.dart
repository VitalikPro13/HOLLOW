import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/server_folder_popup.dart';
import 'package:hollow/src/ui/server_settings/delete_channel_confirm.dart';
import 'package:hollow/src/ui/server_settings/pages/access_page.dart';
import 'package:hollow/src/ui/server_settings/pages/labels_page.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';
import 'package:hollow/src/ui/settings/category_bulk_access_dialog.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';
import 'package:hollow/src/ui/settings/moderation_dialogs.dart';
import 'package:hollow/src/ui/settings/server_template.dart';

import '../helpers/test_app.dart';

/// Dialogs pass, agent 3 part A: server settings, member moderation and the
/// folder popup after the fixes. Invented content only; FFI mocked.
///
/// Output: build/ui_screenshots/dialogs_after/3/a_*.png
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

const _sid = 'srv-1';
const _mira = 'peer_mira_1111111111';
const _juno = 'peer_juno_2222222222';
const _sam = 'peer_sam_33333333333';
const _vip = crdt_api.LabelFfi(
    labelId: 'vip', name: 'Patron', color: '#8B5CF6', access: true);
const _artist = crdt_api.LabelFfi(
    labelId: 'artist', name: 'Artist', color: '#22C55E', access: false);
const _staff = crdt_api.LabelFfi(
    labelId: 'staff', name: 'Crew', color: '#06B6D4', access: true);

crdt_api.MemberFfi _member(String peer, String role,
        [List<crdt_api.LabelFfi> labels = const []]) =>
    crdt_api.MemberFfi(
        peerId: peer,
        displayName: '',
        role: role,
        nickname: '',
        twitchUsername: '',
        labels: labels);

class _Api implements RustLibApi {
  @override
  Future<twitch_api.TwitchChannelLookup?> crateApiTwitchTwitchLookupChannel(
      {required String login}) async {
    if (login == 'lofi_nights') {
      return const twitch_api.TwitchChannelLookup(
          id: '481516', login: 'lofi_nights', displayName: 'Lofi_Nights');
    }
    return null;
  }

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      null;

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        for (final (peer, name) in const [
          (_mira, 'Mira'),
          (_juno, 'Juno'),
          (_sam, 'Sam'),
        ])
          peer: storage_api.UserProfile(
            peerId: peer,
            displayName: name,
            status: '',
            aboutMe: '',
            updatedAt: 0,
            twitchUsername: '',
            showcaseBoard: '',
            avatarFrame: '',
            avatarAnim: '',
            bannerAnim: '',
            supportCreds: '',
          ),
      };
}

class _Avatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir =
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}dialogs_after${sep}3';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
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

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir${Platform.pathSeparator}a_$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;
  late WidgetRef hostRef;

  final now = DateTime.now().millisecondsSinceEpoch;
  final overrides = <Override>[
    profileProvider.overrideWith(_Profiles.new),
    avatarProvider.overrideWith(_Avatars.new),
    myRoleProvider(_sid).overrideWith((ref) async => 'owner'),
    myPermissionsProvider(_sid).overrideWith((ref) async => Permission.all),
    serverLabelsProvider(_sid)
        .overrideWith((ref) async => const [_vip, _staff, _artist]),
    serverMembersProvider(_sid).overrideWith((ref) async => [
          _member(_mira, 'moderator', const [_vip]),
          _member(_juno, 'member', const [_artist]),
          _member(_sam, 'member'),
        ]),
    serverChannelsProvider(_sid).overrideWith((ref) async => const {
          'c-lounge': ChannelInfo(
              channelId: 'c-lounge',
              name: 'patron-lounge',
              visibilityLabels: ['vip']),
          'c-stage': ChannelInfo(
              channelId: 'c-stage',
              name: 'backstage',
              channelType: ChannelType.voice,
              visibilityLabels: ['staff']),
        }),
    channelGrantsProvider((serverId: _sid, channelId: 'c-lounge'))
        .overrideWith((ref) async => [
              crdt_api.ChannelGrantFfi(
                  peerId: _mira,
                  expiresAtMs: now + 90 * 60 * 1000,
                  permanent: false),
              const crdt_api.ChannelGrantFfi(
                  peerId: _sam, expiresAtMs: 0, permanent: true),
            ]),
    channelGrantsProvider((serverId: _sid, channelId: 'c-stage'))
        .overrideWith((ref) async => const []),
  ];

  Future<void> pumpHost(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: overrides),
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
    ));
    await tester.pump();
    final c = ProviderScope.containerOf(host, listen: false);
    c.read(serverListProvider.notifier).state = {
      _sid: const ServerInfo(serverId: _sid, name: 'Night Shift'),
      'srv-2': const ServerInfo(serverId: 'srv-2', name: 'Game Den'),
    };
  }

  final scenarios = <String, Future<void> Function(WidgetTester)>{
    'manage_member': (tester) async {
      unawaited(showManageMemberDialog(host, serverId: _sid, peerId: _mira));
      await settle(tester);
    },
    'manage_member_loading': (tester) async {
      final c = ProviderScope.containerOf(host, listen: false);
      c.invalidate(serverMembersProvider(_sid));
      unawaited(showManageMemberDialog(host, serverId: _sid, peerId: _mira));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    },
    'manage_member_duration': (tester) async {
      unawaited(showManageMemberDialog(host, serverId: _sid, peerId: _juno));
      await settle(tester);
      await tester.tap(find.text('Give access').first);
      await settle(tester);
    },
    'grants': (tester) async {
      unawaited(showChannelGrantsDialog(host,
          serverId: _sid, channelId: 'c-lounge', channelName: 'patron-lounge'));
      await settle(tester);
    },
    'bulk_access': (tester) async {
      unawaited(showCategoryBulkAccessDialog(host,
          serverId: _sid, categoryName: 'Community', channelCount: 4));
      await settle(tester);
      await tester.tap(find.byType(HollowToggle).first);
      await settle(tester);
      await tester.tap(find.text('Mod+').first);
      await settle(tester);
    },
    'label_picker': (tester) async {
      unawaited(showAccessLabelPicker(
          context: host,
          serverId: _sid,
          target: '#patron-lounge',
          initial: const {'vip'}));
      await settle(tester);
    },
    'template_confirm': (tester) async {
      unawaited(showTemplateConfirmDialog(
          host,
          const ServerTemplate(
              version: 1,
              name: 'Study club',
              description: 'Quiet hours',
              channels: [],
              channelLayout: []),
          const TemplateDiff(
            nameChange: 'Study club',
            descriptionChange: 'Quiet hours',
            channelsToAdd: [
              TemplateChannel(
                  templateId: 't1', name: 'focus-room', channelType: 'voice'),
              TemplateChannel(
                  templateId: 't2', name: 'resources', channelType: 'text'),
            ],
            channelsToRemove: [
              ChannelInfo(channelId: 'x1', name: 'memes'),
              ChannelInfo(channelId: 'x2', name: 'off-topic'),
            ],
          )));
      await settle(tester);
    },
    'delete_channel': (tester) async {
      unawaited(confirmDeleteChannel(host,
          serverId: _sid, channelId: 'c-lounge', channelName: 'patron-lounge'));
      await settle(tester);
    },
    'delete_server': (tester) async {
      unawaited(confirmDeleteServer(host, hostRef, _sid));
      await settle(tester);
    },
    'change_role': (tester) async {
      unawaited(showChangeRoleDialog(host, hostRef,
          serverId: _sid,
          peerId: _juno,
          displayName: 'Juno',
          newRole: 'moderator',
          currentRole: 'member'));
      await settle(tester);
    },
    'ban': (tester) async {
      unawaited(showBanMemberDialog(host, hostRef,
          serverId: _sid, peerId: _juno, displayName: 'Juno'));
      await settle(tester);
    },
    'mute': (tester) async {
      unawaited(showMuteMemberDialog(host, hostRef,
          serverId: _sid, peerId: _juno, displayName: 'Juno'));
      await settle(tester);
    },
    'label_edit': (tester) async {
      showLabelEditDialog(host, serverId: _sid, existing: _vip);
      await settle(tester);
    },
    'label_give': (tester) async {
      unawaited(showLabelAssignDialog(host, serverId: _sid, label: _vip));
      await settle(tester);
    },
    'twitch_found': (tester) async {
      unawaited(showHollowDialog<void>(
          context: host,
          builder: (_) => const TwitchChannelDialog(name: '', id: '')));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'lofi_nights');
      await tester.pump(const Duration(milliseconds: 700));
      await settle(tester);
    },
    'twitch_missing': (tester) async {
      unawaited(showHollowDialog<void>(
          context: host,
          builder: (_) => const TwitchChannelDialog(name: '', id: '')));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'nobody_here');
      await tester.pump(const Duration(milliseconds: 700));
      await settle(tester);
    },
    'folder_rename': (tester) async {
      showFolderRenameDialog(
          context: host,
          ref: hostRef,
          folder: const FolderStripItem(
              id: 'f1', name: 'Games', serverIds: [_sid, 'srv-2']));
      await settle(tester);
    },
  };

  for (final entry in scenarios.entries) {
    testWidgets('${entry.key} desktop', (tester) async {
      await pumpHost(tester, const Size(1440, 900));
      await entry.value(tester);
      await capture(tester, '${entry.key}_desktop');
      await tester.pumpWidget(const SizedBox());
    }, variant: _desktop);
    testWidgets('${entry.key} phone', (tester) async {
      await pumpHost(tester, const Size(390, 844));
      await entry.value(tester);
      await capture(tester, '${entry.key}_phone');
      await tester.pumpWidget(const SizedBox());
    }, variant: _phone);
  }

  testWidgets('folder popup desktop', (tester) async {
    await pumpHost(tester, const Size(1440, 900));
    const folder =
        FolderStripItem(id: 'f1', name: 'Games', serverIds: [_sid, 'srv-2']);
    ProviderScope.containerOf(host, listen: false)
        .read(serverStripLayoutProvider.notifier)
        .state = [folder];
    showServerFolderPopup(
      context: host,
      ref: hostRef,
      folder: folder,
      anchor: const Offset(80, 120),
      isDock: false,
      onServerSelected: (_) {},
    );
    await settle(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Night Shift').last));
    await settle(tester);
    await capture(tester, 'folder_popup_hover_desktop');
    await tester.pumpWidget(const SizedBox());
  }, variant: _desktop);
}

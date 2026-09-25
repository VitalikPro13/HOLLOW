import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/image_pick.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/emotes.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/pinned_messages.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart'
    show showLocalNicknameDialog;
import 'package:hollow/src/ui/dialogs/confirm_remove_friend.dart';
import 'package:hollow/src/ui/mobile/mobile_channel_actions.dart';
import 'package:hollow/src/ui/mobile/mobile_message_actions.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_friends_tab.dart';
import 'package:hollow/src/ui/shell/channel_context_menus.dart'
    show confirmClearLabelGate;
import 'package:hollow/src/ui/shell/conference_dashboard.dart';
import 'package:hollow/src/ui/shell/identity_unlock_dialogs.dart';
import 'package:hollow/src/ui/shell/voice_room_switch.dart';

import '../helpers/test_app.dart';

/// "After" renders of the dialogs pass, folder 4 (chat, shell, mobile):
/// desktop 1440x900 and phone 390x844, dark. All names are invented.
///
/// Output: $HOLLOW_SHOT_DIR/dialogs_after/4, else
/// build/ui_screenshots/dialogs_after/4.
const _me = '12D3KooWSamSamSamSamSamSamSamSamSamSamSamSamSam';
const _ada = '12D3KooWAdaAdaAdaAdaAdaAdaAdaAdaAdaAdaAdaAdaAda';
const _juno = '12D3KooWJunoJunoJunoJunoJunoJunoJunoJunoJunoJu';
const _desk = Size(1440, 900);
const _phone = Size(390, 844);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${sep}build${sep}ui_screenshots'}'
      '${sep}dialogs_after${sep}4';

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
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;
  late WidgetRef hostRef;

  Future<void> pumpHost(WidgetTester tester, Size size,
      {List<Override> extra = const [], Widget? home}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [..._base(), ...extra]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              host = context;
              hostRef = ref;
              return home ?? const SizedBox.expand();
            }),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// Renders the dialog [open] shows at both sizes.
  void both(String name, Future<void> Function(WidgetTester t) open,
      {List<Override> extra = const [],
      Future<void> Function(WidgetTester t)? then}) {
    for (final (size, tag) in [(_desk, 'desktop'), (_phone, 'phone')]) {
      testWidgets('$name $tag', (t) async {
        await pumpHost(t, size, extra: extra);
        await open(t);
        await settle(t);
        if (then != null) {
          await then(t);
          await settle(t);
        }
        await capture(t, '${name}_$tag');
      });
    }
  }

  Future<void> tap(WidgetTester t, String text) async {
    await t.pump();
    await t.tap(find.text(text).last, warnIfMissed: false);
    await settle(t);
  }

  both('remove_friend', (t) async {
    unawaited(confirmRemoveFriend(host, hostRef, peerId: _ada, name: 'Ada'));
  });
  both('remove_friend_failed', (t) async {
    unawaited(confirmRemoveFriend(host, hostRef, peerId: _ada, name: 'Ada'));
  }, extra: [friendsProvider.overrideWith(() => _Friends(fail: true))],
      then: (t) => tap(t, 'Remove friend'));
  both('nickname', (t) async {
    unawaited(showLocalNicknameDialog(host, hostRef, _ada,
        currentNickname: 'Ada from book club'));
  });
  both('voice_switch', (t) async {
    await ProviderScope.containerOf(host)
        .read(localDevicePeerIdProvider.future);
    unawaited(confirmVoiceRoomSwitch(host, hostRef,
        serverId: 's1', channelId: 'stage', channelName: 'stage'));
  }, extra: [
    voiceChannelProvider.overrideWith(() => _Voice()),
    localDevicePeerIdProvider.overrideWith((ref) async => 'dev-self'),
  ]);
  both('unlock_pin_wrong', (t) async {
    unawaited(showHollowDialog<String>(
        context: host,
        builder: (_) =>
            const UnlockDialog(isPin: true, hasBiometric: true, wrong: true)));
  });
  both('unlock_password', (t) async {
    unawaited(showHollowDialog<String>(
        context: host,
        builder: (_) =>
            const UnlockDialog(isPin: false, hasBiometric: false)));
  });
  RecoveryPhraseDialog locked() => RecoveryPhraseDialog(
        title: 'Identity locked',
        paragraphs: const [
          "This identity is tied to another device, so it can't open here.",
          'Enter your 24-word recovery phrase to use it on this device.',
        ],
        confirmLabel: 'Recover identity',
        cancellable: false,
        onRecover: (_) async => throw Exception('bad'),
      );
  both('identity_locked', (t) async {
    unawaited(showHollowDialog<bool>(context: host, builder: (_) => locked()));
  });
  both('identity_locked_short_phrase', (t) async {
    unawaited(showHollowDialog<bool>(context: host, builder: (_) => locked()));
  }, then: (t) async {
    await t.enterText(find.byType(TextField), 'river stone lamp');
    await tap(t, 'Recover identity');
  });
  both('recover_identity', (t) async {
    unawaited(showHollowDialog<bool>(
        context: host,
        builder: (_) => RecoveryPhraseDialog(
              title: 'Recover identity',
              paragraphs: const [
                'Enter your 24-word recovery phrase to get back into this '
                    'identity.',
                'This turns off your app PIN. You can set a new one in '
                    'Settings.',
              ],
              confirmLabel: 'Recover',
              onRecover: (_) async {},
            )));
  });
  both('conference_create_failed', (t) async {
    unawaited(showConferenceRoomFormDialog(host));
  }, extra: [conferenceProvider.overrideWith(_Conference.new)],
      then: (t) async {
    await t.enterText(find.byType(TextField).first, 'Weekly sync');
    await tap(t, 'Create');
  });
  both('conference_edit_with_code', (t) async {
    unawaited(showConferenceRoomFormDialog(host,
        room: const ConferenceRoom(
            confId: 'c1',
            name: 'Weekly sync',
            waitingRoom: true,
            hasAccessCode: true,
            broadcastMode: false,
            createdAt: 0)));
  });
  both('conference_edit_remove_code', (t) async {
    unawaited(showConferenceRoomFormDialog(host,
        room: const ConferenceRoom(
            confId: 'c1',
            name: 'Weekly sync',
            waitingRoom: true,
            hasAccessCode: true,
            broadcastMode: false,
            createdAt: 0)));
  }, then: (t) => tap(t, 'Remove access code'));
  both('conference_join_failed', (t) async {
    unawaited(showJoinConferenceDialog(host));
  }, extra: [conferenceProvider.overrideWith(_Conference.new)],
      then: (t) async {
    await t.enterText(find.byType(TextField), 'weekly-sync-4821');
    await tap(t, 'Join');
  });
  both('label_gate_confirm', (t) async {
    unawaited(confirmClearLabelGate(host,
        channelName: 'staff-room', tier: 'admin', forVisibility: true));
  });

  final pins = [
    ChannelChatMessage(
        senderId: _ada,
        text: 'Meeting moved to Thursday, same time. Bring the list.',
        isMe: false,
        messageId: 'p1',
        timestamp: DateTime.now().subtract(const Duration(hours: 2))),
    ChannelChatMessage(
        senderId: _me,
        text: 'Rules: be kind, no spoilers past chapter 12.',
        isMe: true,
        messageId: 'p2',
        timestamp: DateTime(2026, 8, 30, 18, 5)),
  ];
  // Someone who may pin, so each row carries Unpin.
  final pinner = [
    myPermissionsProvider('s1')
        .overrideWith((ref) async => Permission.manageChannels),
  ];
  testWidgets('pinned desktop', (t) async {
    await pumpHost(t, _desk, extra: pinner);
    showPinnedMessages(host,
        serverId: 's1',
        channelId: 'c1',
        pinnedIds: const ['p1', 'p2', 'p-old', 'p-older'],
        messages: pins,
        preview: (m) => m.text,
        onJump: (_) {});
    await settle(t);
    await capture(t, 'pinned_desktop');
    // Unpin shows on the hovered row only.
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.text(pins.first.text)));
    await settle(t);
    await capture(t, 'pinned_desktop_hover');
  });
  testWidgets('pinned phone', (t) async {
    await pumpHost(t, _phone, extra: pinner);
    showPinnedMessages(host,
        serverId: 's1',
        channelId: 'c1',
        pinnedIds: const ['p1', 'p2', 'p-old'],
        messages: pins,
        preview: (m) => m.text,
        onJump: (_) {},
        touch: true);
    await settle(t);
    await capture(t, 'pinned_phone');
  });

  both('emote_processing_failed', (t) async {
    debugArmedImagePick = () async => base64Decode(_png);
    unawaited(pickAndNameEmote(host));
  }, then: (t) async {
    await t.enterText(find.byType(TextField), 'pe_wave');
    await tap(t, 'Save');
  });

  // ---- phone sheets

  Future<void> phone(WidgetTester t, String name,
      void Function() open, {List<Override> extra = const [],
      Future<void> Function(WidgetTester t)? then}) async {
    await pumpHost(t, _phone, extra: extra);
    open();
    await settle(t);
    if (then != null) {
      await then(t);
      await settle(t);
    }
    await capture(t, name);
  }

  testWidgets('channel sheet manager', (t) async {
    await phone(
        t,
        'channel_sheet_manager_phone',
        () => showMobileChannelActions(
            context: host,
            serverId: 's1',
            channel: const ChannelInfo(
                channelId: 'c', name: 'book-club', visibility: 'moderator'),
            canManage: true));
  });
  testWidgets('channel sheet member', (t) async {
    await phone(
        t,
        'channel_sheet_member_phone',
        () => showMobileChannelActions(
            context: host,
            serverId: 's1',
            channel: const ChannelInfo(channelId: 'c', name: 'book-club'),
            canManage: false));
  });
  testWidgets('channel sheet visibility', (t) async {
    await phone(
        t,
        'channel_sheet_visibility_phone',
        () => showMobileChannelActions(
            context: host,
            serverId: 's1',
            channel: const ChannelInfo(
                channelId: 'c', name: 'book-club', visibility: 'admin'),
            canManage: true),
        then: (t) => tap(t, 'Visibility'));
  });
  testWidgets('message sheet', (t) async {
    await phone(
        t,
        'message_sheet_phone',
        () => showMobileMessageActions(
              context: host,
              messageText: 'Meeting moved to Thursday, same time.',
              senderName: 'Sam',
              timestamp: '18:05',
              isMe: true,
              onReply: () {},
              onEdit: () {},
              onDelete: () {},
              onCopy: () {},
              onPin: () {},
              onInfo: () {},
            ));
  });
  testWidgets('pending join sheet', (t) async {
    await phone(
        t,
        'pending_join_sheet_phone',
        () => showPendingJoinSheet(
            context: host, ref: hostRef, serverId: 'srv-pending'),
        extra: [pendingJoinsProvider.overrideWith(_Pending.new)]);
  });
  testWidgets('friend sheet', (t) async {
    await pumpHost(t, _phone, home: const MobileFriendsTab());
    await settle(t);
    await t.longPress(find.text('Ada').first);
    await settle(t);
    await capture(t, 'friend_sheet_phone');
  });
  testWidgets('server sheet', (t) async {
    await pumpHost(t, _phone,
        home: const MobileChatsTab(),
        extra: [
          serverListProvider.overrideWith(_Servers.new),
          myRoleProvider.overrideWith((ref, id) async => 'owner'),
          myPermissionsProvider.overrideWith((ref, id) async => 0xFFFFFFFF),
        ]);
    await settle(t);
    await ProviderScope.containerOf(host).read(myRoleProvider('s1').future);
    await ProviderScope.containerOf(host)
        .read(myPermissionsProvider('s1').future);
    await t.longPress(find.text('Night Owls Book Club').first);
    await settle(t);
    await capture(t, 'server_sheet_owner_phone');
    await tap(t, 'Delete server');
    await capture(t, 'server_delete_confirm_phone');
  });
}

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAABNSURBVDhPY7hjY/OfEjycDfh/nQEDY1OH1QBsmmEYXS2GAdg0oWNk9dQ1AJtibBhZzyDzAgxj0wTD6GqxGgDCxGgGYZwGEIsH2gCb/wBSPnarPKl6tgAAAABJRU5ErkJggg==';

storage_api.UserProfile _profile(String peer, String name) =>
    storage_api.UserProfile(
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
    );

List<Override> _base() => [
      identityProvider.overrideWith(_Identity.new),
      profileProvider.overrideWith(_Profiles.new),
      avatarProvider.overrideWith(_Avatars.new),
      friendsProvider.overrideWith(() => _Friends()),
    ];

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState(peerId: _me, isLoaded: true);
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        _me: _profile(_me, 'Sam'),
        _ada: _profile(_ada, 'Ada'),
        _juno: _profile(_juno, 'Juno'),
      };
}

class _Avatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

class _Friends extends FriendsNotifier {
  _Friends({this.fail = false});
  final bool fail;

  @override
  Map<String, FriendInfo> build() => {
        for (final p in [_ada, _juno])
          p: FriendInfo(
              peerId: p,
              status: 'accepted',
              direction: '',
              requestedAt: 0,
              updatedAt: 0),
      };

  @override
  Future<void> removeFriend(String peerId) async {
    if (fail) throw Exception('boom');
  }
}

class _Voice extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        participants: {
          's1': {
            'lobby': {'dev-self', _ada},
          },
        },
        currentServerId: 's1',
        currentChannelId: 'lobby',
        currentChannelName: 'lobby',
      );
}

class _Conference extends ConferenceNotifier {
  @override
  ConferenceState build() => const ConferenceState(roomsLoaded: true);

  @override
  Future<ConferenceRoom> createRoom({
    required String name,
    required bool waitingRoom,
    String? accessCode,
    bool broadcastMode = false,
  }) async =>
      throw Exception('boom');

  @override
  Future<void> requestJoin(String confId, {String? accessCode}) async =>
      throw Exception('boom');
}

class _Pending extends PendingJoinsNotifier {
  @override
  Map<String, PendingJoinInfo> build() => const {
        'srv-pending': PendingJoinInfo(serverId: 'srv-pending', requestedAt: 0),
      };
}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => const {
        's1': ServerInfo(
            serverId: 's1', name: 'Night Owls Book Club', memberCount: 12),
      };
}

class _Api implements RustLibApi {
  @override
  Future<ProcessedEmote> crateApiEmotesProcessAndStoreEmote(
          {required List<int> rawBytes}) async =>
      throw StateError('decoder panic');

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<List<crdt_api.ChannelFfi>> crateApiCrdtGetServerChannels(
          {required String serverId}) async =>
      const [];

  @override
  Future<String> crateApiCrdtGetChannelLayout({required String serverId}) async =>
      '';

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

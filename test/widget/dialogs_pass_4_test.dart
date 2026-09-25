import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/image_pick.dart';
import 'package:hollow/src/rust/api/emotes.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/pinned_messages.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart'
    show showLocalNicknameDialog;
import 'package:hollow/src/ui/dialogs/confirm_remove_friend.dart';
import 'package:hollow/src/ui/mobile/mobile_channel_actions.dart';
import 'package:hollow/src/ui/mobile/mobile_message_actions.dart';
import 'package:hollow/src/ui/shell/conference_dashboard.dart';
import 'package:hollow/src/ui/shell/identity_unlock_dialogs.dart';
import 'package:hollow/src/ui/shell/server_context_menus.dart';
import 'package:hollow/src/ui/shell/voice_room_switch.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Dialogs pass, folder 4 (chat, shell, mobile): each test pins a bug the
/// pass fixed, so it fails on the code before the fix.
void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));

  late BuildContext host;
  late WidgetRef hostRef;

  Future<void> pump(WidgetTester tester,
      {List<Override> overrides = const [],
      Size size = const Size(1200, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: overrides),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            host = context;
            hostRef = ref;
            return const SizedBox.expand();
          }),
        ),
      ),
    ));
  }

  HollowButton button(WidgetTester tester, String label) =>
      tester.widget<HollowButton>(find.ancestor(
          of: find.text(label), matching: find.byType(HollowButton)));

  group('switching voice rooms', () {
    const self = 'dev-self';
    VoiceChannelState inRoom(Set<String> people) => VoiceChannelState(
          participants: {
            's1': {'lobby': people},
          },
          currentServerId: 's1',
          currentChannelId: 'lobby',
          currentChannelName: 'lobby',
        );

    test('asks only when someone else is in the room we would leave', () {
      bool leaves(VoiceChannelState vc, {String to = 'stage'}) =>
          voiceSwitchLeavesPeople(vc,
              serverId: 's1', channelId: to, master: kLocalPeerId, device: self);
      expect(leaves(const VoiceChannelState()), isFalse);
      expect(leaves(inRoom({self})), isFalse);
      // The set is device-keyed, but an old master-keyed self entry is us too.
      expect(leaves(inRoom({self, kLocalPeerId})), isFalse);
      expect(leaves(inRoom({self, 'someone'})), isTrue);
      expect(leaves(inRoom({self, 'someone'}), to: 'lobby'), isFalse);
    });

    Future<Future<bool>> ask(
        WidgetTester tester, VoiceChannelState vc) async {
      await pump(tester, overrides: [
        voiceChannelProvider.overrideWith(() => _Voice(vc)),
        localDevicePeerIdProvider.overrideWith((ref) async => self),
      ]);
      await ProviderScope.containerOf(host)
          .read(localDevicePeerIdProvider.future);
      final answer = confirmVoiceRoomSwitch(host, hostRef,
          serverId: 's1', channelId: 'stage', channelName: 'stage');
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('an empty room switches without a question', (tester) async {
      final answer = await ask(tester, inRoom({self}));
      expect(find.byType(HollowDialog), findsNothing);
      expect(await answer, isTrue);
    });

    testWidgets('a room with people in it asks first', (tester) async {
      final answer = await ask(tester, inRoom({self, 'someone'}));
      expect(find.text('Switch voice room?'), findsOneWidget);
      expect(find.text("You'll leave #lobby and join #stage."), findsOneWidget);
      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
      expect(await answer, isTrue);
    });
  });

  testWidgets('deleting one message on a phone does not ask', (tester) async {
    await pump(tester, size: const Size(390, 844));
    var deleted = 0;
    showMobileMessageActions(
      context: host,
      messageText: 'hello',
      senderName: 'Me',
      timestamp: '12:00',
      isMe: true,
      onDelete: () => deleted++,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete message'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
    expect(find.text('Delete this message?'), findsNothing);
    expect(find.byType(HollowDialog), findsNothing);
  });

  group('remove friend', () {
    testWidgets('a failure stays in the dialog, in words', (tester) async {
      final friends = _Friends()..fail = true;
      await pump(tester, overrides: [friendsProvider.overrideWith(() => friends)]);
      final done = confirmRemoveFriend(host, hostRef,
          peerId: kFriendPeerId1, name: 'Ada');
      await tester.pumpAndSettle();
      expect(find.text('Remove Ada?'), findsOneWidget);
      expect(button(tester, 'Remove friend').variant,
          HollowButtonVariant.danger);
      await tester.tap(find.text('Remove friend'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Ada?'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.text('Friend removed'), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await done, isFalse);
    });

    testWidgets('success closes and says so once it is done', (tester) async {
      final friends = _Friends();
      await pump(tester, overrides: [friendsProvider.overrideWith(() => friends)]);
      final done = confirmRemoveFriend(host, hostRef,
          peerId: kFriendPeerId1, name: 'Ada');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove friend'));
      await tester.pump();
      expect(await done, isTrue);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Friend removed'), findsOneWidget);
      expect(friends.removed, [kFriendPeerId1]);
      await tester.pumpAndSettle(const Duration(seconds: 4));
    });
  });

  group('nickname', () {
    testWidgets('Enter saves, and a failed save keeps the dialog and text',
        (tester) async {
      final nicks = _Nicknames()..fail = true;
      await pump(tester,
          overrides: [localNicknameProvider.overrideWith(() => nicks)]);
      unawaited(showLocalNicknameDialog(host, hostRef, kFriendPeerId1));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Ada');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(nicks.saved, ['Ada']);
      expect(find.text('Set nickname'), findsOneWidget);
      expect(find.text('Ada'), findsOneWidget);

      nicks.fail = false;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Set nickname'), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 4));
    });
  });

  group('unlock and recovery', () {
    Future<void> show(WidgetTester tester, Widget dialog) async {
      await pump(tester);
      unawaited(showHollowDialog<Object?>(context: host, builder: (_) => dialog));
      await tester.pumpAndSettle();
    }

    testWidgets('a wrong PIN is said on the field, in the lock type\'s word',
        (tester) async {
      await show(tester,
          const UnlockDialog(isPin: true, hasBiometric: true, wrong: true));
      expect(find.text('Enter your app PIN to unlock your identity.'),
          findsOneWidget);
      expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
      // The biometric extra is an icon button beside the other ghost action,
      // not a second button next to Unlock.
      final bio = find.byWidgetPredicate((w) =>
          w is HollowIconButton && w.label == 'Unlock with biometrics');
      expect(bio, findsOneWidget);
      expect(
          tester.getTopLeft(bio).dx,
          lessThan(tester.getTopLeft(find.text('Unlock')).dx -
              HollowButton.touchHeight));
    });

    testWidgets('a phrase of the wrong length is caught on the field',
        (tester) async {
      var ran = false;
      await show(
          tester,
          RecoveryPhraseDialog(
            title: 'Recover identity',
            paragraphs: const ['Enter your phrase.'],
            confirmLabel: 'Recover',
            onRecover: (_) async => ran = true,
          ));
      await tester.enterText(find.byType(TextField), 'one two three');
      await tester.tap(find.text('Recover'));
      await tester.pumpAndSettle();
      expect(find.text('A recovery phrase is 24 words. This one has 3.'),
          findsOneWidget);
      expect(ran, isFalse);
    });

    testWidgets('a failed recovery shows a sentence, never the exception',
        (tester) async {
      await show(
          tester,
          RecoveryPhraseDialog(
            title: 'Recover identity',
            paragraphs: const ['Enter your phrase.'],
            confirmLabel: 'Recover',
            onRecover: (_) async => throw Exception('bad checksum'),
          ));
      final phrase = List.filled(24, 'word').join(' ');
      await tester.enterText(find.byType(TextField), phrase);
      await tester.tap(find.text('Recover'));
      await tester.pumpAndSettle();
      expect(find.textContaining("That phrase didn't open this identity"),
          findsOneWidget);
      expect(find.textContaining('bad checksum'), findsNothing);
      expect(find.text(phrase), findsOneWidget);
    });
  });

  group('conferences', () {
    testWidgets('a failed create keeps the form and what was typed',
        (tester) async {
      await pump(tester, overrides: [
        conferenceProvider.overrideWith(() => _Conference()),
      ]);
      unawaited(showConferenceRoomFormDialog(host));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Weekly sync');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Create room'), findsOneWidget);
      expect(find.text('Weekly sync'), findsOneWidget);
      expect(find.text("Couldn't create the room. Try again."), findsOneWidget);
    });

    testWidgets('a failed join is shown, not swallowed', (tester) async {
      await pump(tester, overrides: [
        conferenceProvider.overrideWith(() => _Conference()),
      ]);
      unawaited(showJoinConferenceDialog(host));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'meeting123');
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(find.text('Join a meeting'), findsOneWidget);
      expect(find.text("Couldn't reach the meeting. Try again."),
          findsOneWidget);
    });
  });

  group('pinned messages', () {
    final loaded = ChannelChatMessage(
      senderId: kFriendPeerId1,
      text: 'the plan',
      isMe: false,
      messageId: 'm1',
      timestamp: DateTime(2026, 9, 1, 10),
    );

    test('pins older than the loaded history are counted, not dropped', () {
      final r = resolvePinnedMessages(['m1', 'm-old'], [loaded]);
      expect(r.loaded.map((m) => m.messageId), ['m1']);
      expect(r.missing, 1);
    });

    testWidgets('the list owns up to missing pins and a row jumps',
        (tester) async {
      await pump(tester);
      String? jumped;
      showPinnedMessages(
        host,
        serverId: 's1',
        channelId: 'c1',
        pinnedIds: const ['m1', 'm-old'],
        messages: [loaded],
        preview: (m) => m.text,
        onJump: (id) => jumped = id,
      );
      await tester.pumpAndSettle();
      expect(find.text(pinnedMissingLine(1)), findsOneWidget);
      await tester.tap(find.text('the plan'));
      await tester.pumpAndSettle();
      expect(jumped, 'm1');
      expect(find.text('Pinned messages'), findsNothing);
    });
  });

  testWidgets('an emote image that fails to process says so in the dialog',
      (tester) async {
    await pump(tester);
    debugArmedImagePick = () async => base64Decode(_png);
    final result = pickAndNameEmote(host);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'pe_test');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Name this emote'), findsOneWidget);
    expect(find.text("Hollow couldn't use that image. Try another one."),
        findsOneWidget);
    expect(button(tester, 'Save').onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  group('phone channel sheet', () {
    testWidgets('a voice channel opens nothing for someone who cannot manage it',
        (tester) async {
      await pump(tester, size: const Size(390, 844));
      showMobileChannelActions(
        context: host,
        serverId: 's1',
        channel: const ChannelInfo(
            channelId: 'v', name: 'lounge', channelType: ChannelType.voice),
        canManage: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('lounge'), findsNothing);
    });

    testWidgets('a member gets the rows they can use, not an empty sheet',
        (tester) async {
      await pump(tester, size: const Size(390, 844));
      showMobileChannelActions(
        context: host,
        serverId: 's1',
        channel: const ChannelInfo(channelId: 't', name: 'general'),
        canManage: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Mark as read'), findsOneWidget);
      expect(find.text('Mute channel'), findsOneWidget);
      expect(find.text('Rename channel'), findsNothing);
    });
  });

  testWidgets('the strip menu offers an owner Delete, since an owner cannot '
      'leave', (tester) async {
    await pump(tester, overrides: [
      myRoleProvider.overrideWith((ref, id) async => 'owner'),
    ]);
    showServerIconMenu(
      context: host,
      ref: hostRef,
      serverId: 's1',
      anchor: const Offset(100, 100),
      onOpenSettings: () {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete server'), findsOneWidget);
    expect(find.text('Leave server'), findsNothing);
  });
}

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAABNSURBVDhPY7hjY/OfEjycDfh/nQEDY1OH1QBsmmEYXS2GAdg0oWNk9dQ1AJtibBhZzyDzAgxj0wTD6GqxGgDCxGgGYZwGEIsH2gCb/wBSPnarPKl6tgAAAABJRU5ErkJggg==';

class _Api implements RustLibApi {
  @override
  Future<ProcessedEmote> crateApiEmotesProcessAndStoreEmote(
          {required List<int> rawBytes}) async =>
      throw StateError('decoder panic: frame 3');

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Voice extends VoiceChannelNotifier {
  _Voice(this.initial);
  final VoiceChannelState initial;

  @override
  VoiceChannelState build() => initial;
}

class _Friends extends FriendsNotifier {
  bool fail = false;
  final removed = <String>[];

  @override
  Map<String, FriendInfo> build() => testFriends;

  @override
  Future<void> removeFriend(String peerId) async {
    if (fail) throw Exception('Node is not running');
    removed.add(peerId);
  }
}

class _Nicknames extends LocalNicknameNotifier {
  bool fail = false;
  final saved = <String>[];

  @override
  Map<String, String> build() => {};

  @override
  Future<void> setNickname(String peerId, String nickname) async {
    saved.add(nickname);
    if (fail) throw Exception('disk full');
  }
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

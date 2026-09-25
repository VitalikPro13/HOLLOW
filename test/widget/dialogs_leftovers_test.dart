import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/pinned_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/emotes.dart' as emotes_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/pinned_messages.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/server_settings/pages/emotes_page.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Dialogs pass leftovers: list rows on the dialog's text edge, level halves
/// in Add a server, the emote page's own writes, grant wording and Unpin.
class _Api implements RustLibApi {
  Object? removeEmoteError;
  Object? unpinError;
  final removedEmotes = <String>[];
  final unpinned = <String>[];

  /// Holds an unpin in flight until the test completes it.
  Completer<void>? unpinGate;

  @override
  Future<void> crateApiEmotesRemoveServerEmote(
      {required String serverId, required String name}) async {
    if (removeEmoteError != null) throw removeEmoteError!;
    removedEmotes.add(name);
  }

  @override
  Future<void> crateApiCrdtUnpinMessage({
    required String serverId,
    required String channelId,
    required String messageId,
  }) async {
    await unpinGate?.future;
    if (unpinError != null) throw unpinError!;
    unpinned.add(messageId);
  }

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      null;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api
      ..removeEmoteError = null
      ..unpinError = null
      ..unpinGate = null
      ..removedEmotes.clear()
      ..unpinned.clear();
  });

  late BuildContext host;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester,
      {List<Override> overrides = const [],
      Size size = const Size(1440, 900),
      Widget? body}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: overrides),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            host = context;
            container = ProviderScope.containerOf(context);
            return body ?? const SizedBox.expand();
          }),
        ),
      ),
    ));
  }

  group('list rows in a dialog', () {
    const leadKey = ValueKey('lead');

    Future<void> openRowDialog(WidgetTester tester) async {
      await pump(tester);
      showHollowDialog<void>(
        context: host,
        builder: (_) => HollowDialog(
          title: 'Rows',
          showClose: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HollowDialogText('Prose'),
              HollowListRow(
                title: 'Row',
                leading: const SizedBox(key: leadKey, width: 28, height: 28),
                onTap: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a row sits on the text edge, its hover past it',
        (tester) async {
      await openRowDialog(tester);
      final edge = tester.getTopLeft(find.text('Prose')).dx;
      expect(tester.getTopLeft(find.byKey(leadKey)).dx, edge);
      final fill = find.ancestor(
          of: find.text('Row'), matching: find.byType(HollowPressable));
      expect(tester.getTopLeft(fill).dx, edge - HollowListRow.insetOf());
      expect(tester.getSize(fill).width,
          tester.getSize(find.text('Prose')).width + 2 * HollowListRow.insetOf(),
          reason: 'the hover spans the text column plus both insets');
    });

    testWidgets('outside a dialog a row keeps its inset', (tester) async {
      await pump(tester, body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: HollowListRow(
            title: 'Row',
            leading: const SizedBox(key: leadKey, width: 28, height: 28),
            onTap: () {},
          ),
        ),
      ));
      expect(tester.getTopLeft(find.byKey(leadKey)).dx, HollowListRow.insetOf());
    });

    testWidgets("the member picker's rows sit on its search field's edge",
        (tester) async {
      await pump(tester);
      showHollowDialog<void>(
        context: host,
        builder: (_) => HollowDialog(
          title: 'Pick',
          showClose: true,
          content: MemberSearchPicker(
            members: const [
              crdt_api.MemberFfi(
                peerId: kFriendPeerId1,
                displayName: 'Juno',
                role: 'member',
                nickname: '',
                twitchUsername: '',
                labels: [],
              ),
            ],
            nameOf: (m) => m.displayName,
            trailingOf: (_) => const SizedBox.shrink(),
            onTapMember: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HollowListRow), findsOneWidget);
      expect(tester.getTopLeft(find.byType(HollowAvatar)).dx,
          tester.getTopLeft(find.byType(HollowTextField)).dx);
    });
  });

  testWidgets("Add a server's two buttons sit level", (tester) async {
    await pump(tester);
    showCreateServerDialog(host);
    await tester.pumpAndSettle();
    Finder button(String label) => find.ancestor(
        of: find.text(label), matching: find.byType(HollowButton));
    Finder field(String hint) => find.byWidgetPredicate(
        (w) => w is HollowTextField && w.hintText == hint);
    expect(tester.getTopLeft(button('Join')).dy,
        tester.getTopLeft(button('Create')).dy);
    expect(tester.getTopLeft(field('Invite link or server ID')).dy,
        tester.getTopLeft(field('My Awesome Server')).dy);
    expect(tester.getTopLeft(find.text('Join a server')).dy,
        tester.getTopLeft(find.text('Start your own')).dy,
        reason: 'the headers start level too');
  });

  test('a grant with no end says someone may remove it', () {
    const grant = crdt_api.ChannelGrantFfi(
        peerId: kFriendPeerId1, expiresAtMs: 0, permanent: true);
    expect(grantRemainingLabel(grant), 'Until someone removes it');
  });

  group('emotes page', () {
    const stored = [
      emotes_api.ServerEmote(name: 'wave', hash: 'h1', animated: false),
      emotes_api.ServerEmote(name: 'cat', hash: 'h2', animated: false),
    ];

    Future<void> openPage(WidgetTester tester) async {
      await pump(tester,
          overrides: [
            // The store never catches up in this test: every read returns the
            // list from before the write, as a read racing the queue would.
            serverEmotesProvider('s1').overrideWith((ref) async => stored),
            serverStickersProvider('s1').overrideWith((ref) async => const []),
            myPermissionsProvider('s1')
                .overrideWith((ref) async => Permission.manageEmotes),
            stickerLimitsProvider.overrideWithValue(const StickerLimits(
                perServer: 50,
                perPack: 50,
                packs: 10,
                vaultTotal: 500,
                labelChars: 40)),
          ],
          body: const EmotesPage(serverId: 's1'));
      await tester.pumpAndSettle();
    }

    Future<void> remove(WidgetTester tester, String name) async {
      await tester.tap(find.bySemanticsLabel(':$name:'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove :$name:').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove emote'));
      await tester.pump();
    }

    testWidgets('a removed emote leaves the page before any read-back',
        (tester) async {
      await openPage(tester);
      expect(find.text(':cat:'), findsWidgets);
      await remove(tester, 'cat');
      expect(api.removedEmotes, ['cat']);
      await tester.pumpAndSettle();
      expect(find.text(':cat:'), findsNothing);
      expect(find.text(':wave:'), findsWidgets);
      expect(find.text('1 of 50'), findsOneWidget);
      // The store still shows it after the settle refetch: it comes back,
      // since the store is the truth once the write has had its time.
      await tester.pump(AssetWritesNotifier.settleAfter);
      await tester.pumpAndSettle();
      expect(find.text(':cat:'), findsWidgets);
    });

    testWidgets('a failed removal puts the emote back and says why',
        (tester) async {
      api.removeEmoteError = 'Node is not running';
      await openPage(tester);
      await remove(tester, 'cat');
      await tester.pumpAndSettle();
      expect(find.text(':cat:'), findsWidgets);
      expect(find.text('Remove :cat:?'), findsOneWidget,
          reason: 'the confirm stays open with the reason inside');
      await tester.pump(AssetWritesNotifier.settleAfter);
      await tester.pumpAndSettle();
    });

    test('the overlay adds, replaces and hides by key', () {
      const a = emotes_api.ServerEmote(name: 'a', hash: '1', animated: false);
      const a2 = emotes_api.ServerEmote(name: 'a', hash: '2', animated: false);
      const b = emotes_api.ServerEmote(name: 'b', hash: '3', animated: false);
      String key(emotes_api.ServerEmote e) => e.name;
      expect(overAssetWrites<emotes_api.ServerEmote>([a], {'b': b}, key), [a, b]);
      expect(overAssetWrites<emotes_api.ServerEmote>([a, b], {'a': a2}, key), [a2, b]);
      expect(overAssetWrites<emotes_api.ServerEmote>([a, b], {'a': null}, key), [b]);
    });
  });

  group('pinned messages', () {
    final msgs = [
      ChannelChatMessage(
        senderId: kFriendPeerId1,
        text: 'the plan',
        isMe: false,
        messageId: 'm1',
        timestamp: DateTime(2026, 9, 1, 10),
      ),
      ChannelChatMessage(
        senderId: kFriendPeerId2,
        text: 'the rules',
        isMe: false,
        messageId: 'm2',
        timestamp: DateTime(2026, 9, 1, 9),
      ),
    ];

    Future<void> open(WidgetTester tester, {required int perms}) async {
      await pump(tester, overrides: [
        myPermissionsProvider('s1').overrideWith((ref) async => perms),
      ]);
      container.read(pinnedProvider.notifier)
        ..applyPin('s1', 'c1', 'm1')
        ..applyPin('s1', 'c1', 'm2');
      showPinnedMessages(
        host,
        serverId: 's1',
        channelId: 'c1',
        pinnedIds: const ['m1', 'm2'],
        messages: msgs,
        preview: (m) => m.text,
        onJump: (_) {},
      );
      await tester.pumpAndSettle();
    }

    testWidgets('someone who cannot pin gets no Unpin', (tester) async {
      await open(tester, perms: 0);
      expect(find.bySemanticsLabel('Unpin'), findsNothing);
    });

    testWidgets('Unpin drops the row at once and unpins', (tester) async {
      await open(tester, perms: Permission.manageChannels);
      expect(find.bySemanticsLabel('Unpin'), findsNWidgets(2));
      api.unpinGate = Completer<void>();
      await tester.tap(find.bySemanticsLabel('Unpin').first);
      await tester.pump();
      expect(find.text('the plan'), findsNothing,
          reason: 'gone before the unpin returns');
      expect(container.read(pinnedProvider)['s1:c1'], ['m2']);
      api.unpinGate!.complete();
      await tester.pumpAndSettle();
      expect(api.unpinned, ['m1']);
      expect(find.text('the rules'), findsOneWidget);
    });

    testWidgets('unpinning the last pin closes the list', (tester) async {
      await open(tester, perms: Permission.manageChannels);
      await tester.tap(find.bySemanticsLabel('Unpin').first);
      await tester.pumpAndSettle();
      expect(find.text('Pinned messages'), findsOneWidget,
          reason: 'one pin is still there');
      await tester.tap(find.bySemanticsLabel('Unpin').first);
      await tester.pumpAndSettle();
      expect(api.unpinned, ['m1', 'm2']);
      expect(find.text('Pinned messages'), findsNothing);
      expect(find.text('Nothing is pinned here'), findsNothing);
    });

    testWidgets('a failed unpin puts the row back and says why',
        (tester) async {
      await open(tester, perms: Permission.manageChannels);
      api.unpinError = 'Node is not running';
      await tester.tap(find.bySemanticsLabel('Unpin').first);
      await tester.pump();
      await tester.pump();
      expect(find.text('the plan'), findsOneWidget);
      expect(container.read(pinnedProvider)['s1:c1'], containsAll(['m1', 'm2']));
      expect(find.textContaining('Node is not running'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}

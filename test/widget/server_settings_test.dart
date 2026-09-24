/// A server's settings as a place: the rail shows only the pages the viewer's
/// permissions open, the default page follows them, text edits raise the one
/// unsaved bar, a channel row says only what differs, the roles table locks
/// the columns above you, and Members puts moderation first.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/mobile/mobile_server_settings_route.dart';
import 'package:hollow/src/ui/server_settings/pages/channels_page.dart';
import 'package:hollow/src/ui/server_settings/pages/members_page.dart';
import 'package:hollow/src/ui/server_settings/pages/roles_page.dart';
import 'package:hollow/src/ui/server_settings/server_settings_place.dart';
import 'package:hollow/src/ui/settings/settings_place.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

const _owner = Permission.all;
const _member = Permission.sendMessages | Permission.readMessages;
const _admin = Permission.all;

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => testServers;
}

crdt_api.MemberFfi _m(String id, String name, String role,
        {List<crdt_api.LabelFfi> labels = const []}) =>
    crdt_api.MemberFfi(
      peerId: id,
      displayName: name,
      role: role,
      nickname: name,
      twitchUsername: '',
      labels: labels,
    );

final _members = [
  _m(kLocalPeerId, 'Vitalik', 'owner'),
  _m('p_admin', 'Dr Faust', 'admin'),
  _m('p_mod', 'Kestrel', 'moderator'),
  _m('p_mira', 'Mira', 'member'),
  _m('p_oren', 'oren', 'member'),
];

List<Override> _overrides({
  required int perms,
  required String role,
  Map<String, String> settings = const {},
}) =>
    hollowTestOverrides(extra: [
      serverListProvider.overrideWith(_Servers.new),
      myPermissionsProvider(kServerId1).overrideWith((_) async => perms),
      myRoleProvider(kServerId1).overrideWith((_) async => role),
      serverSettingProvider
          .overrideWith((ref, a) async => settings[a.key] ?? ''),
      serverMembersProvider(kServerId1).overrideWith((_) async => _members),
      serverLabelsProvider(kServerId1)
          .overrideWith((_) async => const <crdt_api.LabelFfi>[]),
      mutedMembersProvider(kServerId1)
          .overrideWith((_) async => const <crdt_api.MutedMemberFfi>[]),
      bannedMembersProvider(kServerId1).overrideWith((_) async => const []),
      serverEmotesProvider(kServerId1).overrideWith((_) async => const []),
      serverStickersProvider(kServerId1).overrideWith((_) async => const []),
      channelGrantsProvider.overrideWith((ref, a) async => const []),
      serverChannelsProvider(kServerId1)
          .overrideWith((_) async => testChannels),
      rolePermissionsProvider(kServerId1).overrideWith((_) async => {
            'admin': (perms: Permission.all, defaults: Permission.all),
            'moderator': (
              perms: Permission.kickMembers |
                  Permission.sendMessages |
                  Permission.readMessages,
              defaults: Permission.kickMembers |
                  Permission.sendMessages |
                  Permission.readMessages,
            ),
            'member': (perms: _member, defaults: _member),
          }),
    ]);

Future<ProviderContainer> _pumpPlace(
  WidgetTester tester, {
  required int perms,
  required String role,
  ServerSettingsPage? page,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(
      overrides: _overrides(perms: perms, role: role));
  addTearDown(container.dispose);
  container.read(selectedServerProvider.notifier).state = kServerId1;
  openServerSettings(container.read, kServerId1, page: page);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: ServerSettingsPlace()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

List<String> _railLabels(WidgetTester tester) => [
      for (final item
          in tester.widgetList<SettingsRailItem>(find.byType(SettingsRailItem)))
        item.label,
    ];

String? _selectedRail(WidgetTester tester) => tester
    .widgetList<SettingsRailItem>(find.byType(SettingsRailItem))
    .where((i) => i.selected)
    .firstOrNull
    ?.label;

void main() {
  group('rail', () {
    testWidgets('a plain member sees their own pages, starting on Profile',
        (tester) async {
      await _pumpPlace(tester, perms: _member, role: 'member');
      expect(_railLabels(tester),
          ['Emotes and stickers', 'Members', 'Profile', 'Notifications']);
      expect(_selectedRail(tester), 'Profile');
      expect(find.text('You'), findsOneWidget);
    });

    testWidgets('the owner sees every page, starting on Overview',
        (tester) async {
      await _pumpPlace(tester, perms: _owner, role: 'owner');
      expect(_railLabels(tester), [
        'Overview',
        'Access',
        'Channels',
        'Roles',
        'Labels',
        'Emotes and stickers',
        'Members',
        'Profile',
        'Notifications',
      ]);
      expect(_selectedRail(tester), 'Overview');
      expect(find.text('Server settings'), findsOneWidget);
    });

    testWidgets('Escape closes the place', (tester) async {
      final c = await _pumpPlace(tester, perms: _member, role: 'member');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.read(serverSettingsOpenProvider), isFalse);
    });
  });

  group('unsaved bar', () {
    testWidgets('a nickname edit raises it and Reset clears it',
        (tester) async {
      await _pumpPlace(tester, perms: _member, role: 'member');
      expect(find.text('You have unsaved server changes'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'Vee');
      await tester.pump();
      expect(find.text('You have unsaved server changes'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(find.text('You have unsaved server changes'), findsNothing);
    });
  });

  group('channel summary', () {
    const plain = ChannelInfo(
      channelId: 'c',
      name: 'general',
      channelType: ChannelType.text,
      visibility: 'everyone',
      posting: 'everyone',
    );

    test('a default channel says nothing', () {
      expect(channelSummary(plain), '');
    });

    test('only what differs, in reading order', () {
      final ch = plain.copyWith(
        visibility: 'moderator',
        posting: 'admin',
        slowModeSecs: 30,
        mediaOnly: true,
        isPublic: true,
      );
      expect(channelSummary(ch, grants: 2),
          'Mod+ can see · Admin+ can post · Slow 30s · Media only · Public · '
          '2 members with temporary access');
    });

    test('a label gate names its label', () {
      const patreon = crdt_api.LabelFfi(
          labelId: 'l1', name: 'Patreon', color: '#D4A017', access: true);
      final ch = plain.copyWith(visibility: 'admin', visibilityLabels: ['l1']);
      expect(channelSummary(ch, labels: [patreon]), 'Patreon can see');
    });

    test('a voice channel ignores text-only settings', () {
      final ch = plain.copyWith(
          channelType: ChannelType.voice, posting: 'admin', mediaOnly: true);
      expect(channelSummary(ch), '');
    });
  });

  group('roles', () {
    testWidgets('an admin cannot change the Admin column', (tester) async {
      await _pumpPlace(tester,
          perms: _admin, role: 'admin', page: ServerSettingsPage.roles);
      await tester.pump();
      final toggles =
          tester.widgetList<HollowToggle>(find.byType(HollowToggle)).toList();
      expect(toggles, hasLength(21));
      // Row by row: Admin, Moderator, Member.
      for (var i = 0; i < toggles.length; i += 3) {
        expect(toggles[i].onChanged, isNull);
        expect(toggles[i + 1].onChanged, isNotNull);
        expect(toggles[i + 2].onChanged, isNotNull);
      }
      expect(find.text('These are the defaults. Changes apply at once.'),
          findsOneWidget);
    });
  });

  group('members', () {
    testWidgets('moderation comes first, and the filter narrows the list',
        (tester) async {
      await _pumpPlace(tester,
          perms: _owner, role: 'owner', page: ServerSettingsPage.members);
      await tester.pump();
      final moderation = tester.getTopLeft(find.text('Moderation')).dy;
      final everyone = tester.getTopLeft(find.text('Everyone')).dy;
      expect(moderation, lessThan(everyone));
      expect(find.text('Mira'), findsOneWidget);
      expect(find.text('Kestrel'), findsOneWidget);

      await tester.tap(find.text('Moderators'));
      await tester.pump();
      expect(find.text('Kestrel'), findsOneWidget);
      expect(find.text('Mira'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'zzz');
      await tester.pump();
      expect(find.text('Nobody here matches that'), findsOneWidget);
    });

    testWidgets('a plain member sees no moderation', (tester) async {
      await _pumpPlace(tester,
          perms: _member, role: 'member', page: ServerSettingsPage.members);
      await tester.pump();
      expect(find.text('Moderation'), findsNothing);
      expect(find.text('Everyone'), findsOneWidget);
    });
  });

  group('phone', () {
    testWidgets('the list shows the member pages with their icons',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final container = ProviderContainer(
          overrides: _overrides(perms: _member, role: 'member'));
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: const MobileServerSettingsRoute(serverId: kServerId1),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      for (final title in [
        'Emotes and stickers',
        'Members',
        'Profile',
        'Notifications',
        'Storage on this phone',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('Overview'), findsNothing);
      expect(find.text('Server settings'), findsOneWidget);
    });
  });
}

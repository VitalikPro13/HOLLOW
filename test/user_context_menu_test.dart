import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/composer_insert_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';

/// The user context menu (issue #61, phase 3) and the keyboard route that
/// makes every context menu reachable without a mouse.
///
/// What is worth asserting here is the GATING, because getting it wrong is
/// both easy and invisible: a moderation row shown to someone who cannot use
/// it produces a confusing Rust rejection, and one hidden from someone who
/// can leaves them thinking the feature does not exist.
void main() {
  const them = 'master_them';

  /// Pumps a host with a right-clickable box wired to the user menu.
  Future<void> pumpMenuHost(
    WidgetTester tester, {
    String? serverId,
    UserMenuSurface surface = UserMenuSurface.generic,
    String myRole = 'member',
    int myPerms = 0,
    String theirRole = 'member',
    bool includeThemInMembers = true,
    String? selectedServer,
    String? selectedChannel,
    ProviderContainer? Function(ProviderContainer)? capture,
  }) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer(overrides: [
      identityProvider.overrideWith(() => _FixedIdentity()),
      if (serverId != null) ...[
        myRoleProvider(serverId).overrideWith((ref) async => myRole),
        myPermissionsProvider(serverId).overrideWith((ref) async => myPerms),
        serverMembersProvider(serverId).overrideWith((ref) async => [
              if (includeThemInMembers)
                crdt_api.MemberFfi(
                  peerId: them,
                  displayName: 'Them',
                  role: theirRole,
                  nickname: '',
                  twitchUsername: '',
                  labels: const [],
                ),
            ]),
      ],
    ]);
    addTearDown(container.dispose);
    capture?.call(container);

    if (selectedServer != null) {
      container.read(selectedServerProvider.notifier).state = selectedServer;
    }
    if (selectedChannel != null) {
      container.read(selectedChannelProvider.notifier).state = selectedChannel;
      container.read(channelListProvider.notifier).setChannels({
        selectedChannel: const ChannelInfo(
          channelId: 'chan',
          name: 'general',
          channelType: ChannelType.text,
        ),
      });
    }

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Center(
                child: ContextMenuTarget(
                  semanticLabel: 'Member actions',
                  onOpen: (anchor) => showUserContextMenu(
                    context: context,
                    ref: ref,
                    peerId: them,
                    serverId: serverId,
                    surface: surface,
                    anchor: anchor,
                  ),
                  child: Focus(
                    autofocus: true,
                    child: Container(
                      key: const ValueKey('target'),
                      width: 200,
                      height: 60,
                      color: const Color(0xFF202020),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> rightClickTarget(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('target')),
        buttons: kSecondaryButton);
    // The menu route animates in; pump it out rather than settling, so a
    // stray perpetual ticker can never wedge the test.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  List<String> menuLabels(WidgetTester tester) => tester
      .widgetList<Text>(find.descendant(
        of: find.byType(HollowMenuScope),
        matching: find.byType(Text),
      ))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  testWidgets('a plain peer with no server gets no moderation rows',
      (tester) async {
    await pumpMenuHost(tester);
    await rightClickTarget(tester);

    final labels = menuLabels(tester);
    expect(labels, contains('Profile'));
    expect(labels, contains('Message'));
    expect(labels, contains('Block'));
    expect(labels, contains('Copy user ID'));
    expect(labels, isNot(contains('Kick member')));
    expect(labels, isNot(contains('Ban member')));
    expect(labels, isNot(contains('Manage member')));
  });

  testWidgets('a member without kick permission sees no moderation trio',
      (tester) async {
    await pumpMenuHost(tester, serverId: 'srv', myRole: 'member');
    await rightClickTarget(tester);

    final labels = menuLabels(tester);
    expect(labels, contains('Profile'));
    expect(labels, isNot(contains('Kick member')));
    expect(labels, isNot(contains('Mute member')));
    expect(labels, isNot(contains('Ban member')));
  });

  testWidgets('an admin with kickMembers sees the moderation trio',
      (tester) async {
    await pumpMenuHost(
      tester,
      serverId: 'srv',
      myRole: 'admin',
      myPerms: Permission.kickMembers | Permission.manageRoles,
    );
    await rightClickTarget(tester);

    final labels = menuLabels(tester);
    expect(labels, contains('Manage member'));
    expect(labels, contains('Mute member'));
    expect(labels, contains('Kick member'));
    expect(labels, contains('Ban member'));
  });

  testWidgets('an admin cannot moderate the owner', (tester) async {
    await pumpMenuHost(
      tester,
      serverId: 'srv',
      myRole: 'admin',
      myPerms: Permission.kickMembers | Permission.manageRoles,
      theirRole: 'owner',
    );
    await rightClickTarget(tester);

    final labels = menuLabels(tester);
    expect(labels, isNot(contains('Kick member')));
    expect(labels, isNot(contains('Ban member')));
  });

  testWidgets('someone who is not a member of the server gets no trio',
      (tester) async {
    await pumpMenuHost(
      tester,
      serverId: 'srv',
      myRole: 'owner',
      myPerms: Permission.all,
      includeThemInMembers: false,
    );
    await rightClickTarget(tester);

    final labels = menuLabels(tester);
    expect(labels, isNot(contains('Kick member')));
    expect(labels, isNot(contains('Manage member')));
  });

  testWidgets('the DM tile surface adds the conversation rows', (tester) async {
    await pumpMenuHost(tester, surface: UserMenuSurface.dmTile);
    await rightClickTarget(tester);

    final labels = menuLabels(tester);
    expect(labels, contains('Mark as read'));
    expect(labels, contains('Mute conversation'));
    expect(labels, contains('Add to favourites'));
    expect(labels, contains('Remove friend'));
  });

  testWidgets('Mention appears only with a text channel open', (tester) async {
    await pumpMenuHost(tester);
    await rightClickTarget(tester);
    expect(menuLabels(tester), isNot(contains('Mention')));
  });

  testWidgets('Mention posts a scoped composer insert', (tester) async {
    ProviderContainer? held;
    await pumpMenuHost(
      tester,
      selectedServer: 'srv',
      selectedChannel: 'chan',
      capture: (c) {
        held = c;
        return c;
      },
    );
    await rightClickTarget(tester);

    expect(menuLabels(tester), contains('Mention'));
    await tester.tap(find.text('Mention'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    final insert = held!.read(composerInsertProvider);
    expect(insert, isNotNull);
    expect(insert!.scope, 'srv:chan');
    expect(insert.text, endsWith(' '));
    expect(insert.text, startsWith('@'));
  });

  testWidgets('Menu key opens the same menu without a pointer', (tester) async {
    await pumpMenuHost(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(menuLabels(tester), contains('Profile'));
  });

  testWidgets('Shift+F10 opens it too', (tester) async {
    await pumpMenuHost(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }

    expect(menuLabels(tester), contains('Profile'));
  });
}

class _FixedIdentity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState(peerId: 'master_me');
}

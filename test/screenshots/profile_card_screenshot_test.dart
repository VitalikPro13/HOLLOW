import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';

/// Screenshot harness for the profile card popup redesign (issue #48
/// follow-up: one primary action + a utility icon strip, no button stack)
/// and the Manage Member dialog. Writes PNGs so the layout can be judged
/// by eye; every test still passes as a "builds and settles" check.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const serverId = 'srv-1';
  const myPeerId = 'me_peer_aaaaaaaaaaaaaaaa';
  const broPeerId = 'peer_virtualbro_AnffNxdk';
  const shotKey = Key('screenshot-boundary');

  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    final fontData =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    final loader = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(Future.value(fontData));
    await loader.load();

    try {
      final segoe = File(r'C:\Windows\Fonts\segoeui.ttf');
      if (segoe.existsSync()) {
        final bytes = segoe.readAsBytesSync();
        for (final family in ['FlutterTest', 'Ahem', 'Roboto']) {
          final l = FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer)));
          await l.load();
        }
      }
    } catch (_) {/* screenshots fall back to block glyphs */}
  });

  const vipLabel = crdt_api.LabelFfi(
      labelId: 'vip', name: 'VIP', color: '#8B5CF6', access: true);
  const funLabel = crdt_api.LabelFfi(
      labelId: 'fun', name: 'Gamer', color: '#22C55E', access: false);

  List<Override> baseOverrides({bool friends = true}) => [
        identityProvider.overrideWith(_MockIdentityNotifier.new),
        profileProvider.overrideWith(_MockProfileNotifier.new),
        avatarProvider.overrideWith(_MockAvatarNotifier.new),
        if (friends) friendsProvider.overrideWith(_MockFriendsNotifier.new),
        myRoleProvider(serverId).overrideWith((ref) async => 'owner'),
        myPermissionsProvider(serverId)
            .overrideWith((ref) async => Permission.all),
        serverLabelsProvider(serverId)
            .overrideWith((ref) async => const [vipLabel, funLabel]),
        serverMembersProvider(serverId).overrideWith((ref) async => const [
              crdt_api.MemberFfi(
                  peerId: myPeerId,
                  displayName: 'Me',
                  role: 'owner',
                  nickname: '',
                  twitchUsername: '',
                  labels: []),
              crdt_api.MemberFfi(
                  peerId: broPeerId,
                  displayName: 'virtual bro',
                  role: 'member',
                  nickname: '',
                  twitchUsername: '',
                  labels: [vipLabel]),
            ]),
        serverChannelsProvider(serverId).overrideWith((ref) async => const {
              'chan-vip': ChannelInfo(
                channelId: 'chan-vip',
                name: 'vip-lounge',
                visibilityLabels: ['vip'],
              ),
              'chan-staff': ChannelInfo(
                channelId: 'chan-staff',
                name: 'staff-voice',
                channelType: ChannelType.voice,
                visibilityLabels: ['vip'],
              ),
              'chan-general': ChannelInfo(
                channelId: 'chan-general',
                name: 'general',
              ),
            }),
        channelGrantsProvider((serverId: serverId, channelId: 'chan-vip'))
            .overrideWith((ref) async => [
                  crdt_api.ChannelGrantFfi(
                    peerId: broPeerId,
                    expiresAtMs: DateTime.now().millisecondsSinceEpoch +
                        90 * 60 * 1000,
                    permanent: false,
                  ),
                ]),
        channelGrantsProvider((serverId: serverId, channelId: 'chan-staff'))
            .overrideWith((ref) async => const []),
      ];

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      try {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data == null) return;
        final file = File('$outDir${Platform.pathSeparator}$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('[screenshot] wrote ${file.path}');
      } catch (e) {
        debugPrint('[screenshot] skipped $name: $e');
      }
    });
  }

  /// Hosts the COMPACT card body inside the popup's real chrome (300px,
  /// surface tint, accent border) against a dark backdrop.
  Future<void> pumpCompactCard(
    WidgetTester tester, {
    required List<Override> overrides,
    String? cardServerId,
  }) async {
    tester.view.physicalSize = const Size(420, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Center(
                child: Builder(builder: (context) {
                  final hollow = HollowTheme.of(context);
                  return Container(
                    width: 300,
                    decoration: BoxDecoration(
                      color: hollow.surface.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(hollow.radiusLg),
                      border: Border.all(
                        color: hollow.accent.withValues(alpha: 0.15),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ProfileCardBody(
                      peerId: broPeerId,
                      role: 'member',
                      labels: const [vipLabel],
                      serverId: cardServerId,
                      density: ProfileCardDensity.compact,
                      dismissHost: () {},
                      onExpand: () {},
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('compact card — friend + staff: primary Message + icon strip',
      (tester) async {
    await pumpCompactCard(
      tester,
      overrides: baseOverrides(),
      cardServerId: serverId,
    );
    expect(find.text('Message'), findsOneWidget);
    expect(find.text('Friends'), findsOneWidget);
    // No stacked text buttons anymore.
    expect(find.text('Edit Nickname'), findsNothing);
    expect(find.text('Block'), findsNothing);
    await capture(tester, 'profile_card_friend_staff');
  });

  testWidgets('compact card — stranger, no server: Add Friend + icon strip',
      (tester) async {
    await pumpCompactCard(
      tester,
      overrides: baseOverrides(friends: false),
      cardServerId: null,
    );
    expect(find.text('Add Friend'), findsOneWidget);
    expect(find.text('Message'), findsNothing);
    await capture(tester, 'profile_card_stranger');
  });

  testWidgets('manage member dialog — overview + duration picker',
      (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(),
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showManageMemberDialog(
                      context,
                      serverId: serverId,
                      peerId: broPeerId,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Manage'), findsWidgets);
    expect(find.text('vip-lounge'), findsOneWidget);
    expect(find.textContaining('left'), findsOneWidget); // active grant row
    await capture(tester, 'manage_member_overview');

    // Grant flow for the ungated-yet channel → duration picker.
    await tester.tap(find.text('Grant'));
    await tester.pumpAndSettle();
    expect(find.textContaining('How long'), findsOneWidget);
    await capture(tester, 'manage_member_duration');
  });
}

class _MockIdentityNotifier extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState(
        peerId: 'me_peer_aaaaaaaaaaaaaaaa',
        isLoaded: true,
      );
}

class _MockProfileNotifier extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {
        'peer_virtualbro_AnffNxdk': const storage_api.UserProfile(
          peerId: 'peer_virtualbro_AnffNxdk',
          displayName: 'virtual bro',
          status: 'VM',
          aboutMe: 'Local VM sibling for multi-device testing.',
          updatedAt: 0,
          twitchUsername: '',
          showcaseBoard: '',
          avatarFrame: '',
          avatarAnim: '',
          bannerAnim: '',
        ),
      };
}

/// Avatars: never touch FFI — every peer falls back to initials.
class _MockAvatarNotifier extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

class _MockFriendsNotifier extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => {
        'peer_virtualbro_AnffNxdk': const FriendInfo(
          peerId: 'peer_virtualbro_AnffNxdk',
          status: 'accepted',
          direction: '',
          requestedAt: 0,
          updatedAt: 0,
        ),
      };
}

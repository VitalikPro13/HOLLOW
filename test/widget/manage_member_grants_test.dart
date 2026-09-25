import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';

/// Manage member and temporary access: loading is never shown as "not a
/// member", and a revoke drops the row at once without waiting on a read-back
/// (the refetch right after a queued write still returns the old grant),
/// coming back only when the write fails.
void main() {
  const serverId = 'srv-1';
  const bro = 'bro_peer_bbbbbbbbbbbbbbbb';
  final api = _Api();

  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => api.revokeFails = false);

  final staleGrant = crdt_api.ChannelGrantFfi(
    peerId: bro,
    expiresAtMs: DateTime.now().millisecondsSinceEpoch + 90 * 60 * 1000,
    permanent: false,
  );

  const broMember = crdt_api.MemberFfi(
      peerId: bro,
      displayName: 'Juno',
      role: 'member',
      nickname: '',
      twitchUsername: '',
      labels: []);

  List<Override> overrides({
    Future<List<crdt_api.MemberFfi>>? members,
    Future<int>? perms,
  }) =>
      [
        identityProvider.overrideWith(_Identity.new),
        profileProvider.overrideWith(_Profiles.new),
        avatarProvider.overrideWith(_Avatars.new),
        myRoleProvider(serverId).overrideWith((ref) async => 'owner'),
        myPermissionsProvider(serverId)
            .overrideWith((ref) => perms ?? Future.value(Permission.all)),
        serverLabelsProvider(serverId).overrideWith((ref) async => const []),
        serverMembersProvider(serverId).overrideWith(
            (ref) => members ?? Future.value(const [broMember])),
        serverChannelsProvider(serverId).overrideWith((ref) async => const {
              'chan-vip': ChannelInfo(
                  channelId: 'chan-vip',
                  name: 'vip-lounge',
                  visibilityLabels: ['vip']),
            }),
        // Always the pre-write answer, like a read right after a write.
        channelGrantsProvider((serverId: serverId, channelId: 'chan-vip'))
            .overrideWith((ref) async => [staleGrant]),
      ];

  Future<void> open(WidgetTester tester, List<Override> overrides,
      void Function(BuildContext context) show) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => show(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('Manage member', () {
    testWidgets('loading members shows a spinner, not "no longer a member"',
        (tester) async {
      final pending = Completer<List<crdt_api.MemberFfi>>();
      await open(
          tester,
          overrides(members: pending.future),
          (c) => showManageMemberDialog(c, serverId: serverId, peerId: bro));
      expect(find.byType(HollowSpinner), findsOneWidget);
      expect(find.textContaining('member of this server'), findsNothing);
      pending.complete(const [broMember]);
      await tester.pumpAndSettle();
      expect(find.text('vip-lounge'), findsOneWidget);
    });

    testWidgets('loading permissions never reads as no permission',
        (tester) async {
      final pending = Completer<int>();
      await open(tester, overrides(perms: pending.future),
          (c) => showManageMemberDialog(c, serverId: serverId, peerId: bro));
      expect(find.byType(HollowSpinner), findsOneWidget);
      expect(find.textContaining('permission'), findsNothing);
      pending.complete(Permission.all);
      await tester.pumpAndSettle();
      expect(find.text('vip-lounge'), findsOneWidget);
    });

    testWidgets('a member who left says so once the list has loaded',
        (tester) async {
      await open(
          tester,
          overrides(members: Future.value(const [])),
          (c) => showManageMemberDialog(c, serverId: serverId, peerId: bro));
      await tester.pumpAndSettle();
      expect(find.textContaining("isn't a member of this server anymore"),
          findsOneWidget);
    });

    testWidgets('revoke is a grey icon button and drops the grant at once',
        (tester) async {
      await open(tester, overrides(),
          (c) => showManageMemberDialog(c, serverId: serverId, peerId: bro));
      await tester.pumpAndSettle();
      final revoke = find.byWidgetPredicate((w) =>
          w is HollowIconButton && w.label == 'Remove access to #vip-lounge');
      expect(revoke, findsOneWidget);
      expect(tester.widget<HollowIconButton>(revoke).color, isNull);

      await tester.tap(revoke);
      await tester.pumpAndSettle();
      // The provider still answers with the old grant; the row stays revoked.
      expect(revoke, findsNothing);
      expect(find.text('Give access'), findsOneWidget);
    });

    testWidgets('a failed revoke puts the grant back', (tester) async {
      api.revokeFails = true;
      await open(tester, overrides(),
          (c) => showManageMemberDialog(c, serverId: serverId, peerId: bro));
      await tester.pumpAndSettle();
      await tester.tap(find.byWidgetPredicate((w) =>
          w is HollowIconButton && w.label == 'Remove access to #vip-lounge'));
      await tester.pumpAndSettle();
      expect(find.textContaining('left'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('Temporary access', () {
    testWidgets('a revoke drops the row at once, with no read-back delay',
        (tester) async {
      await open(
          tester,
          overrides(),
          (c) => showChannelGrantsDialog(c,
              serverId: serverId,
              channelId: 'chan-vip',
              channelName: 'vip-lounge'));
      await tester.pumpAndSettle();
      expect(find.text('Temporary access to #vip-lounge'), findsOneWidget);
      expect(find.text('Has access now'), findsOneWidget);
      final revoke = find.byWidgetPredicate((w) =>
          w is HollowIconButton && w.label.startsWith('Remove access for '));
      await tester.tap(revoke);
      await tester.pumpAndSettle();
      expect(find.text('Has access now'), findsNothing);
    });

    testWidgets('the id suffix only shows when two people share a name',
        (tester) async {
      await open(
          tester,
          overrides(),
          (c) => showChannelGrantsDialog(c,
              serverId: serverId,
              channelId: 'chan-vip',
              channelName: 'vip-lounge'));
      await tester.pumpAndSettle();
      expect(find.textContaining('…'), findsNothing);
    });
  });
}

class _Api implements RustLibApi {
  bool revokeFails = false;

  @override
  Future<void> crateApiCrdtRevokeChannelAccess({
    required String serverId,
    required String channelId,
    required String peerId,
  }) async {
    if (revokeFails) throw 'Node is not running';
  }

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() =>
      const IdentityState(peerId: 'me_peer_aaaaaaaaaaaaaaaa', isLoaded: true);
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => const {};
}

class _Avatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

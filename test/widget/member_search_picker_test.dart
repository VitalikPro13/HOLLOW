import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/member_search_picker.dart';
import 'package:hollow/src/ui/settings/labels_tab.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Member picker search contract:
///  - empty query lists every member, each with the short peer-id suffix
///    ("…" + last 6) so same-named members stay distinguishable,
///  - the filter matches display name, nickname AND raw peer id
///    (case-insensitive substring — a pasted id works),
///  - no matches shows the 'No members match' state, never a blank card,
///  - the desktop Assign dialog carries the same picker and pre-checks
///    members that already hold the label.
void main() {
  const serverId = 'srv-1';

  const vipLabel = crdt_api.LabelFfi(
      labelId: 'vip', name: 'VIP', color: '#8B5CF6', access: true);

  const members = [
    crdt_api.MemberFfi(
        peerId: 'peer_nova_1111111111111111',
        displayName: 'Nova',
        role: 'member',
        nickname: 'Nova',
        twitchUsername: '',
        labels: []),
    crdt_api.MemberFfi(
        peerId: 'peer_nova_6666666666666666',
        displayName: 'Nova',
        role: 'member',
        nickname: 'Nova',
        twitchUsername: '',
        labels: []),
    crdt_api.MemberFfi(
        peerId: 'peer_faust_222222222222222',
        displayName: 'DrFaust',
        role: 'member',
        nickname: 'DrFaust',
        twitchUsername: '',
        labels: []),
    crdt_api.MemberFfi(
        peerId: 'peer_kestrel_3333333333333',
        displayName: 'Kestrel',
        role: 'moderator',
        nickname: 'Kestrel',
        twitchUsername: '',
        labels: [vipLabel]),
    crdt_api.MemberFfi(
        peerId: 'peer_lyra_44444444444444444',
        displayName: 'Lyra',
        role: 'member',
        nickname: 'Lyra',
        twitchUsername: '',
        labels: []),
  ];

  Future<void> pumpPicker(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [avatarProvider.overrideWith(_MockAvatarNotifier.new)],
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: MemberSearchPicker(
                  members: members,
                  maxListHeight: 400,
                  nameOf: (m) => m.nickname,
                  trailingOf: (_) => const SizedBox.shrink(),
                  onTapMember: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shortPeerIdSuffix is ellipsis + last 6', (tester) async {
    expect(shortPeerIdSuffix('peer_nova_1111111111111111'), '…111111');
    expect(shortPeerIdSuffix('short'), 'short');
  });

  testWidgets('empty query lists everyone with id suffixes', (tester) async {
    await pumpPicker(tester);
    expect(find.text('Nova'), findsNWidgets(2));
    expect(find.text('DrFaust'), findsOneWidget);
    expect(find.text('Kestrel'), findsOneWidget);
    expect(find.text('Lyra'), findsOneWidget);
    // Same-name members are told apart by their id suffix.
    expect(find.text('…111111'), findsOneWidget);
    expect(find.text('…666666'), findsOneWidget);
  });

  testWidgets('search filters by name, case-insensitively', (tester) async {
    await pumpPicker(tester);
    await tester.enterText(find.byType(TextField), 'LYRA');
    await tester.pump();
    expect(find.text('Lyra'), findsOneWidget);
    expect(find.text('Nova'), findsNothing);
    expect(find.text('DrFaust'), findsNothing);
    expect(find.text('Kestrel'), findsNothing);
  });

  testWidgets('search matches a pasted raw peer id', (tester) async {
    await pumpPicker(tester);
    await tester.enterText(find.byType(TextField), '666666');
    await tester.pump();
    expect(find.text('Nova'), findsOneWidget); // only the …666666 one
    expect(find.text('…666666'), findsOneWidget);
    expect(find.text('…111111'), findsNothing);
  });

  testWidgets('no matches shows the empty state', (tester) async {
    await pumpPicker(tester);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('No members match'), findsOneWidget);
    expect(find.text('Nova'), findsNothing);
  });

  testWidgets('desktop Assign dialog searches and pre-checks holders',
      (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          avatarProvider.overrideWith(_MockAvatarNotifier.new),
          identityProvider.overrideWith(_MockIdentityNotifier.new),
          profileProvider.overrideWith(_MockProfileNotifier.new),
          serverMembersProvider(serverId).overrideWith((ref) async => members),
        ],
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showLabelAssignDialog(
                    context,
                    serverId: serverId,
                    label: vipLabel,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // All five members, and Kestrel (holds VIP) is pre-checked.
    expect(find.text('Nova'), findsNWidgets(2));
    expect(find.byIcon(LucideIcons.checkSquare), findsOneWidget);
    expect(find.byIcon(LucideIcons.square), findsNWidgets(4));

    await tester.enterText(find.byType(TextField), 'faust');
    await tester.pump();
    expect(find.text('DrFaust'), findsOneWidget);
    expect(find.text('Nova'), findsNothing);
    expect(find.text('Kestrel'), findsNothing);
  });
}

class _MockAvatarNotifier extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
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
  Map<String, storage_api.UserProfile> build() => {};
}

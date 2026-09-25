import 'dart:async';
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
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/server_settings/pages/labels_page.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Labels page writes: Give flips the box BEFORE the write returns and flips
/// back on a failure; the page's overlay shows its own writes over a stale
/// stored list and lets go once the list catches up; every colour swatch
/// has its own name.
void main() {
  const serverId = 'srv-1';
  const vip = crdt_api.LabelFfi(
      labelId: 'vip', name: 'VIP', color: '#ff00ff', access: true);
  final api = _Api();

  setUpAll(() => RustLib.initMock(api: api));

  group('overlay', () {
    test('a delete hides the label until the stored list drops it', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final sub = c.listen(labelWritesProvider(serverId), (_, _) {});
      addTearDown(sub.close);
      final writes = c.read(labelWritesProvider(serverId).notifier);
      writes.removed('vip');
      expect(c.read(labelWritesProvider(serverId)).over(const [vip]), isEmpty);
      writes.prune(const [vip]);
      expect(c.read(labelWritesProvider(serverId)).byId, isNotEmpty,
          reason: 'the store still has it: keep hiding');
      writes.prune(const []);
      expect(c.read(labelWritesProvider(serverId)).byId, isEmpty);
    });

    test('an edit wins over the stale row, and a create shows at once', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final sub = c.listen(labelWritesProvider(serverId), (_, _) {});
      addTearDown(sub.close);
      final writes = c.read(labelWritesProvider(serverId).notifier);
      writes.updated(const crdt_api.LabelFfi(
          labelId: 'vip', name: 'VIP+', color: '#ff00ff', access: true));
      writes.created(const crdt_api.LabelFfi(
          labelId: '', name: 'Artist', color: '#00ff00', access: false));
      final shown = c.read(labelWritesProvider(serverId)).over(const [vip]);
      expect(shown.map((l) => l.name), ['VIP+', 'Artist']);
      expect(LabelWrites.isPending(shown.last), isTrue);

      writes.prune(const [
        crdt_api.LabelFfi(
            labelId: 'vip', name: 'VIP+', color: '#ff00ff', access: true),
        crdt_api.LabelFfi(
            labelId: 'lbl-1', name: 'Artist', color: '#00ff00', access: false),
      ]);
      final state = c.read(labelWritesProvider(serverId));
      expect(state.byId, isEmpty);
      expect(state.created, isEmpty);
    });
  });

  group('Give label', () {
    Future<void> openGive(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          avatarProvider.overrideWith(_Avatars.new),
          identityProvider.overrideWith(_Identity.new),
          profileProvider.overrideWith(_Profiles.new),
          serverMembersProvider(serverId).overrideWith((ref) async => const [
                crdt_api.MemberFfi(
                    peerId: 'peer_nova_111111',
                    displayName: 'Nova',
                    role: 'member',
                    nickname: 'Nova',
                    twitchUsername: '',
                    labels: []),
              ]),
        ],
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showLabelAssignDialog(context,
                      serverId: serverId, label: vip),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the box flips before the write returns', (tester) async {
      api.assign = Completer<void>();
      await openGive(tester);
      await tester.tap(find.text('Nova'));
      await tester.pump();
      expect(find.byIcon(LucideIcons.checkSquare), findsOneWidget);
      api.assign!.complete();
      await tester.pumpAndSettle();
      expect(find.byIcon(LucideIcons.checkSquare), findsOneWidget);
    });

    testWidgets('a failed write flips it back and says so', (tester) async {
      api.assign = Completer<void>();
      await openGive(tester);
      await tester.tap(find.text('Nova'));
      await tester.pump();
      api.assign!.completeError('Node is not running');
      await tester.pumpAndSettle();
      expect(find.byIcon(LucideIcons.checkSquare), findsNothing);
      expect(find.textContaining('starting up'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  testWidgets('each colour swatch has its own name', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () =>
                    showLabelEditDialog(context, serverId: serverId),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final handle = tester.ensureSemantics();
    for (final name in ['Red', 'Blue', 'Grey']) {
      expect(find.bySemanticsLabel(name), findsOneWidget);
    }
    expect(find.bySemanticsLabel('Label colour'), findsNothing);
    expect(find.text('Name'), findsOneWidget);
    handle.dispose();
  });
}

class _Api implements RustLibApi {
  Completer<void>? assign;

  @override
  Future<void> crateApiCrdtAssignLabel({
    required String serverId,
    required String labelId,
    required String peerId,
  }) =>
      assign?.future ?? Future.value();

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Avatars extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() =>
      const IdentityState(peerId: 'me_peer_aaaaaaaaaaaaaaaa', isLoaded: true);
}

class _Profiles extends ProfileNotifier {
  @override
  Map<String, storage_api.UserProfile> build() => {};
}

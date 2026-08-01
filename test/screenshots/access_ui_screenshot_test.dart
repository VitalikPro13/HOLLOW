import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';
import 'package:hollow/src/ui/settings/category_bulk_access_dialog.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart';
import 'package:hollow/src/ui/settings/labels_tab.dart';

/// Screenshot harness for the channel-access dialogs (bulk category access,
/// temporary grants, access-label picker). Renders each dialog OPEN at a
/// 900x700 viewport and writes PNGs so layout polish can be judged by eye.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
/// Writing the PNGs is best-effort — an unwritable dir never fails the suite;
/// every test still passes as a normal "dialog builds and settles" check.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const serverId = 'srv-1';
  const channelId = 'chan-1';
  const myPeerId = 'me_peer_aaaaaaaaaaaaaaaa';
  const shotKey = Key('screenshot-boundary');

  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    // Load the real Lucide glyphs so icons render as icons, not tofu boxes.
    // Package fonts resolve under the "packages/<pkg>/<family>" family name.
    final fontData =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    final loader = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(Future.value(fontData));
    await loader.load();

    // Best-effort: shadow the block-glyph test font with a real system font
    // so screenshots carry readable text. Skipped silently off-Windows.
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

  const labels = [
    crdt_api.LabelFfi(
        labelId: 'vip', name: 'VIP', color: '#8B5CF6', access: true),
    crdt_api.LabelFfi(
        labelId: 'staff', name: 'Staff', color: '#22C55E', access: true),
    crdt_api.LabelFfi(
        labelId: 'early', name: 'Early Supporter', color: '#06B6D4',
        access: true),
  ];

  List<Override> baseOverrides() => [
        identityProvider.overrideWith(_MockIdentityNotifier.new),
        profileProvider.overrideWith(_MockProfileNotifier.new),
        avatarProvider.overrideWith(_MockAvatarNotifier.new),
        serverLabelsProvider(serverId).overrideWith((ref) async => labels),
        serverMembersProvider(serverId).overrideWith((ref) async => const [
              crdt_api.MemberFfi(
                  peerId: myPeerId,
                  displayName: 'Me',
                  role: 'owner',
                  nickname: 'Me',
                  twitchUsername: '',
                  labels: []),
              crdt_api.MemberFfi(
                  peerId: 'peer_nova_1111111111111111',
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
                  labels: [
                    crdt_api.LabelFfi(
                        labelId: 'vip',
                        name: 'VIP',
                        color: '#8B5CF6',
                        access: true),
                  ]),
              crdt_api.MemberFfi(
                  peerId: 'peer_lyra_44444444444444444',
                  displayName: 'Lyra',
                  role: 'member',
                  nickname: 'Lyra',
                  twitchUsername: '',
                  labels: []),
              // Second "Nova" — same display name, different identity, so
              // the short peer-id suffix visibly disambiguates in pickers.
              crdt_api.MemberFfi(
                  peerId: 'peer_nova_6666666666666666',
                  displayName: 'Nova',
                  role: 'member',
                  nickname: 'Nova',
                  twitchUsername: '',
                  labels: []),
            ]),
        channelGrantsProvider((serverId: serverId, channelId: channelId))
            .overrideWith((ref) async => [
                  // One timed grant (~90 min remaining), one permanent.
                  crdt_api.ChannelGrantFfi(
                    peerId: 'peer_nova_1111111111111111',
                    expiresAtMs: DateTime.now().millisecondsSinceEpoch +
                        90 * 60 * 1000,
                    permanent: false,
                  ),
                  const crdt_api.ChannelGrantFfi(
                    peerId: 'peer_faust_222222222222222',
                    expiresAtMs: 0,
                    permanent: true,
                  ),
                ]),
      ];

  Future<void> pumpHost(
    WidgetTester tester, {
    required void Function(BuildContext context) onOpen,
  }) async {
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
                    onPressed: () => onOpen(context),
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
  }

  /// Renders the boundary to a PNG. Never throws on I/O problems — the
  /// screenshot is a dev artifact, not an assertion.
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

  testWidgets('bulk access dialog — sections off', (tester) async {
    await pumpHost(tester, onOpen: (context) {
      showCategoryBulkAccessDialog(
        context,
        serverId: serverId,
        categoryName: 'COMMUNITY',
        channelCount: 3,
      );
    });
    expect(find.text('Apply to 3'), findsOneWidget);
    await capture(tester, 'bulk_access_off');
  });

  testWidgets('bulk access dialog — sections on with chips', (tester) async {
    await pumpHost(tester, onOpen: (context) {
      showCategoryBulkAccessDialog(
        context,
        serverId: serverId,
        categoryName: 'COMMUNITY',
        channelCount: 3,
      );
    });
    await tester.tap(find.byType(HollowToggle).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(HollowToggle).at(1));
    await tester.pumpAndSettle();
    // Vary the selection so both selected and unselected chips are visible.
    await tester.tap(find.text('Admin+').first);
    await tester.pumpAndSettle();
    await capture(tester, 'bulk_access_on');
  });

  testWidgets('channel grants dialog — overview', (tester) async {
    await pumpHost(tester, onOpen: (context) {
      showChannelGrantsDialog(
        context,
        serverId: serverId,
        channelId: channelId,
        channelName: 'staff-lounge',
      );
    });
    expect(find.text('ACTIVE GRANTS'), findsOneWidget);
    expect(find.text('GRANT ACCESS'), findsOneWidget);
    await capture(tester, 'grants_overview');
  });

  testWidgets('channel grants dialog — search filters the picker',
      (tester) async {
    await pumpHost(tester, onOpen: (context) {
      showChannelGrantsDialog(
        context,
        serverId: serverId,
        channelId: channelId,
        channelName: 'staff-lounge',
      );
    });
    await tester.enterText(find.byType(TextField), 'nova');
    await tester.pumpAndSettle();
    await capture(tester, 'grants_search');
  });

  testWidgets('label assign dialog — carded searchable member picker',
      (tester) async {
    await pumpHost(tester, onOpen: (context) {
      showLabelAssignDialog(
        context,
        serverId: serverId,
        label: labels.first, // VIP
      );
    });
    expect(find.text('Nova'), findsNWidgets(2));
    await capture(tester, 'assign_dialog');
  });

  testWidgets('channel grants dialog — duration picker', (tester) async {
    await pumpHost(tester, onOpen: (context) {
      showChannelGrantsDialog(
        context,
        serverId: serverId,
        channelId: channelId,
        channelName: 'staff-lounge',
      );
    });
    await tester.tap(find.text('Kestrel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('How long'), findsOneWidget);
    await capture(tester, 'grants_duration');
  });

  testWidgets('access label picker', (tester) async {
    await pumpHost(tester, onOpen: (context) {
      showAccessLabelPicker(
        context: context,
        serverId: serverId,
        title: 'Custom visibility',
        initial: {'vip'},
      );
    });
    expect(find.text('VIP'), findsOneWidget);
    await capture(tester, 'label_picker');

    // Deselect the only chosen label — the tier-fallback warning appears.
    await tester.tap(find.text('VIP'));
    await tester.pumpAndSettle();
    expect(find.textContaining('tier-based access'), findsOneWidget);
    await capture(tester, 'label_picker_warning');
  });

  testWidgets('access label picker — empty state', (tester) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith(_MockIdentityNotifier.new),
          profileProvider.overrideWith(_MockProfileNotifier.new),
          avatarProvider.overrideWith(_MockAvatarNotifier.new),
          serverLabelsProvider(serverId).overrideWith((ref) async => const []),
        ],
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showAccessLabelPicker(
                      context: context,
                      serverId: serverId,
                      title: 'Custom visibility',
                      initial: const {},
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
    expect(find.textContaining('No access labels yet'), findsOneWidget);
    await capture(tester, 'label_picker_empty');
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
  Map<String, storage_api.UserProfile> build() => {};
}

/// Avatars: never touch FFI — every peer falls back to initials.
class _MockAvatarNotifier extends AvatarNotifier {
  @override
  Map<String, Uint8List> build() => {};

  @override
  Future<void> loadAvatar(String peerId) async {}
}

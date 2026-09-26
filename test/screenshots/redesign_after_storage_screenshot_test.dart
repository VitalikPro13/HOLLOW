import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/mobile_server_settings_route.dart';
import 'package:hollow/src/ui/server_settings/server_settings_place.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// "After" renders of Server settings > Files & storage, which replaced the
/// storage dashboard dialog: desktop (admin and member, small and large,
/// loading, the retention menu, a server that needs attention, light) and the
/// phone page with its picker sheet.
///
/// Output: $HOLLOW_SHOT_DIR/redesign_after, else
/// build/ui_screenshots/redesign_after.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

final _gib = BigInt.from(1024 * 1024 * 1024);
final _mib = BigInt.from(1024 * 1024);

class _Api implements RustLibApi {
  int members = 12;
  Completer<void>? statsGate;

  @override
  Future<crdt_api.StorageStatsFfi> crateApiCrdtGetStorageStats({
    required String serverId,
  }) async {
    await statsGate?.future;
    final small = members < 6;
    return crdt_api.StorageStatsFfi(
      totalPledgedBytes: _gib * BigInt.from(small ? 15 : 60),
      totalUsedBytes: small
          ? _mib * BigInt.from(1843)
          : _mib * BigInt.from(14541),
      myPledgeBytes: _gib * BigInt.from(5),
      myUsedBytes: _mib * BigInt.from(small ? 800 : 600),
      memberCount: members,
      minPledgeMb: BigInt.from(512),
    );
  }

  @override
  Future<storage_api.StorageBreakdown>
  crateApiStorageGetStorageBreakdown() async => storage_api.StorageBreakdown(
    totalDbBytes: _gib,
    totalDiskBytes: _gib,
    vaultCacheBytes: BigInt.zero,
    vaultShardBytes: BigInt.zero,
    assetBlobBytes: BigInt.zero,
    assetBlobCount: 0,
    contexts: [
      storage_api.StorageContextUsage(
        contextType: 'channel',
        contextId: '$kServerId1:general',
        bytesDb: _mib * BigInt.from(members < 6 ? 900 : 1126),
        fileCount: 42,
      ),
    ],
  );

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => {
    for (final e in testServers.entries)
      e.key: e.key == kServerId1
          ? e.value.copyWith(name: 'Synth Lab')
          : e.value,
  };
}

class _Vault extends VaultStatusNotifier {
  _Vault(this.status);
  final Map<String, VaultServerStatus> status;
  @override
  Map<String, VaultServerStatus> build() => status;
}

final _needsAttention = {
  kServerId1: const VaultServerStatus(
    activeUploads: {
      'a': VaultFileStatus(contentId: 'a', phase: 'failed'),
      'b': VaultFileStatus(contentId: 'b', phase: 'failed'),
      'c': VaultFileStatus(contentId: 'c', phase: 'distributing'),
      'd': VaultFileStatus(contentId: 'd', phase: 'distributing'),
      'e': VaultFileStatus(contentId: 'e', phase: 'encoding'),
    },
  ),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${Platform.pathSeparator}build${Platform.pathSeparator}ui_screenshots'}'
      '${Platform.pathSeparator}redesign_after';
  final api = _Api();
  late Directory root;

  setUpAll(() async {
    RustLib.initMock(api: api);
    root = Directory.systemTemp.createTempSync('hollow_storage_shots');
    overrideHollowDataDir(root.path);
    final lucide = await rootBundle.load(
      'packages/lucide_icons_flutter/assets/lucide.ttf',
    );
    await (FontLoader(
      'packages/lucide_icons_flutter/Lucide',
    )..addFont(Future.value(lucide))).load();
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
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    api.members = 12;
    api.statsGate = null;
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(shotKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir${Platform.pathSeparator}$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  /// Unmounts, then outlives the storage breakdown's one-minute keep-alive.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
  }

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  List<Override> overrides({
    required String role,
    Map<String, VaultServerStatus>? vault,
  }) => hollowTestOverrides(
    extra: [
      serverListProvider.overrideWith(_Servers.new),
      myPermissionsProvider(kServerId1).overrideWith(
        (_) async => role == 'member'
            ? Permission.sendMessages | Permission.readMessages
            : Permission.all,
      ),
      myRoleProvider(kServerId1).overrideWith((_) async => role),
      serverSettingProvider.overrideWith(
        (ref, a) async => a.key == 'retention_files' ? '90d' : '',
      ),
      serverMembersProvider(kServerId1).overrideWith((_) async => const []),
      serverLabelsProvider(
        kServerId1,
      ).overrideWith((_) async => const <crdt_api.LabelFfi>[]),
      serverEmotesProvider(kServerId1).overrideWith((_) async => const []),
      serverStickersProvider(kServerId1).overrideWith((_) async => const []),
      serverChannelsProvider(
        kServerId1,
      ).overrideWith((_) async => testChannels),
      vaultStatusProvider.overrideWith(() => _Vault(vault ?? const {})),
    ],
  );

  Future<void> pumpDesktop(
    WidgetTester tester, {
    String role = 'owner',
    bool light = false,
    Map<String, VaultServerStatus>? vault,
    bool wait = true,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: overrides(role: role, vault: vault),
    );
    addTearDown(container.dispose);
    container.read(selectedServerProvider.notifier).state = kServerId1;
    openServerSettings(
      container.read,
      kServerId1,
      page: ServerSettingsPage.storage,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
            home: const Scaffold(body: ServerSettingsPlace()),
          ),
        ),
      ),
    );
    if (wait) await settle(tester);
  }

  Future<void> pumpPhone(WidgetTester tester, {bool light = false}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: overrides(role: 'owner'));
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
            home: const MobileServerSettingsRoute(serverId: kServerId1),
          ),
        ),
      ),
    );
    await settle(tester, rounds: 2);
    await tester.tap(find.text('Files & storage'));
    await settle(tester);
  }

  testWidgets('desktop, large server, admin', (t) async {
    await pumpDesktop(t);
    await capture(t, 'storage_desktop_admin_dark');
    await finish(t);
  }, variant: _desktop);

  testWidgets('desktop, large server, admin, light', (t) async {
    await pumpDesktop(t, light: true);
    await capture(t, 'storage_desktop_admin_light');
    await finish(t);
  }, variant: _desktop);

  testWidgets('desktop, small server, member', (t) async {
    api.members = 3;
    await pumpDesktop(t, role: 'member');
    await capture(t, 'storage_desktop_member_small_dark');
    await finish(t);
  }, variant: _desktop);

  testWidgets('desktop, loading', (t) async {
    api.statsGate = Completer<void>();
    await pumpDesktop(t, wait: false);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await capture(t, 'storage_desktop_loading_dark');
    api.statsGate!.complete();
    await settle(t);
    await finish(t);
  }, variant: _desktop);

  testWidgets('desktop, retention menu open', (t) async {
    await pumpDesktop(t);
    await t.tap(find.text('90 days'));
    await settle(t, rounds: 3);
    await capture(t, 'storage_desktop_menu_dark');
    await finish(t);
  }, variant: _desktop);

  testWidgets('desktop, a server that needs attention', (t) async {
    await pumpDesktop(t, vault: _needsAttention);
    await capture(t, 'storage_desktop_health_dark');
    await finish(t);
  }, variant: _desktop);

  testWidgets('phone, top and lower', (t) async {
    await pumpPhone(t);
    await capture(t, 'storage_phone_top_dark');
    await t.drag(find.byType(Scrollable).last, const Offset(0, -500));
    await settle(t, rounds: 3);
    await capture(t, 'storage_phone_lower_dark');
    await t.tap(find.text('Files'));
    await settle(t, rounds: 4);
    await capture(t, 'storage_phone_sheet_dark');
    await finish(t);
  }, variant: _phone);

  testWidgets('phone, light', (t) async {
    await pumpPhone(t, light: true);
    await capture(t, 'storage_phone_top_light');
    await finish(t);
  }, variant: _phone);
}

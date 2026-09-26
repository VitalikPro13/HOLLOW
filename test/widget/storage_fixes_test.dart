import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/core/services/disk_space.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:hollow/src/ui/server_settings/pages/files_storage_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/test_app.dart';

const _sid = 'srv_storage_test';
final _gib = BigInt.from(1024 * 1024 * 1024);
const _mib = 1024 * 1024;

class _Api implements RustLibApi {
  Object? writeError;
  Completer<void>? statsGate;
  final pledges = <BigInt>[];
  final settings = <String, String>{};
  final cleared = <String>[];
  int members = 3;

  @override
  Future<crdt_api.StorageStatsFfi> crateApiCrdtGetStorageStats({
    required String serverId,
  }) async {
    await statsGate?.future;
    return crdt_api.StorageStatsFfi(
      totalPledgedBytes: _gib * BigInt.from(20),
      totalUsedBytes: _gib * BigInt.from(2),
      myPledgeBytes: _gib,
      myUsedBytes: _gib ~/ BigInt.two,
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
        contextId: '$_sid:general',
        bytesDb: _gib,
        fileCount: 3,
      ),
      storage_api.StorageContextUsage(
        contextType: 'channel',
        contextId: 'other_server:general',
        bytesDb: _gib * BigInt.from(9),
        fileCount: 40,
      ),
    ],
  );

  @override
  Future<BigInt> crateApiStorageClearFileBytesForContext({
    required String contextType,
    required String contextId,
  }) async {
    cleared.add(contextId);
    return _gib;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  Future<String> crateApiCrdtGetServerSetting({
    required String serverId,
    required String key,
  }) async => settings[key] ?? '';

  @override
  Future<void> crateApiCrdtSetStoragePledge({
    required String serverId,
    required BigInt pledgeBytes,
  }) async {
    if (writeError != null) throw writeError!;
    pledges.add(pledgeBytes);
  }

  @override
  Future<void> crateApiCrdtUpdateServerSetting({
    required String serverId,
    required String key,
    required String value,
  }) async {
    if (writeError != null) throw writeError!;
    settings[key] = value;
  }

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Vault extends VaultStatusNotifier {
  @override
  Map<String, VaultServerStatus> build() => const {};
}

final _api = _Api();

Future<void> _pump(
  WidgetTester tester, {
  bool touch = true,
  String role = 'owner',
  bool settle = true,
}) async {
  tester.view.physicalSize = touch
      ? const Size(390, 844)
      : const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(
        extra: [
          vaultStatusProvider.overrideWith(_Vault.new),
          myRoleProvider(_sid).overrideWith((ref) async => role),
        ],
      ),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: SettingsDensity(
            touch: touch,
            child: const SettingsScrollView(
              padding: EdgeInsets.all(HollowSpacing.lg),
              page: FilesStoragePage(serverId: _sid),
            ),
          ),
        ),
      ),
    ),
  );
  if (!settle) return;
  // The free-space read is real I/O.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory root;

  setUpAll(() {
    RustLib.initMock(api: _api);
    root = Directory.systemTemp.createTempSync('hollow_storage_test');
    overrideHollowDataDir(root.path);
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    _api.writeError = null;
    _api.statsGate = null;
    _api.pledges.clear();
    _api.settings.clear();
    _api.cleared.clear();
    _api.members = 3;
  });

  group('free space', () {
    test('reads df -Pk on GNU and BSD alike', () {
      const gnu =
          'Filesystem     1024-blocks      Used Available Capacity '
          'Mounted on\n/dev/nvme0n1p2   479595536 123456789 331724548      28% /\n';
      const mac =
          'Filesystem   1024-blocks      Used Available Capacity  '
          'Mounted on\n/dev/disk3s5   971350180 612345678 350000000    64%    '
          '/System/Volumes/Data\n';
      const spaced =
          'Filesystem 1024-blocks Used Available Capacity Mounted on'
          '\nmap auto_home 0 0 0 100% /System/Volumes/Data/home\n';
      expect(parseDfAvailableBytes(gnu), 331724548 * 1024);
      expect(parseDfAvailableBytes(mac), 350000000 * 1024);
      expect(parseDfAvailableBytes(spaced), 0);
      expect(parseDfAvailableBytes(''), isNull);
    });

    test(
      'reads the volume that holds the data root, even before it exists',
      () async {
        final free = await freeBytesAt(root.path);
        expect(free, isNotNull);
        expect(free, greaterThan(0));
        final later = await freeBytesAt(
          '${root.path}${Platform.pathSeparator}not_made_yet',
        );
        expect(later, isNotNull, reason: 'falls back to the nearest folder');
      },
      skip: Platform.isWindows || Platform.isLinux || Platform.isMacOS
          ? false
          : 'desktop only',
    );

    test('the page reads the data root drive, never a fixed C: or /', () {
      final source = File(
        'lib/src/ui/server_settings/pages/files_storage_page.dart',
      ).readAsStringSync();
      expect(source, isNot(contains('Get-PSDrive C')));
      expect(source, contains('freeBytesAt(hollowDataDir)'));
    });
  });

  testWidgets('loading keeps the geometry and never states 0 B', (
    tester,
  ) async {
    _api.statsGate = Completer<void>();
    await _pump(tester, settle: false);
    await tester.pump();
    expect(find.byType(HollowSkeleton), findsWidgets);
    expect(find.textContaining('0 B'), findsNothing);
    _api.statsGate!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  });

  testWidgets("counts only this server's downloads and what it keeps here", (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('On this phone'), findsOneWidget);
    // 1 GB downloaded from this server plus 0.5 GB kept for it; the other
    // server's 9 GB stays out.
    expect(find.textContaining('1.5 GB'), findsOneWidget);
    expect(find.textContaining('free on this drive'), findsOneWidget);
    expect(
      find.textContaining('Every member keeps a full copy'),
      findsOneWidget,
    );
  });

  testWidgets('a large server explains the split in plain words', (
    tester,
  ) async {
    _api.members = 12;
    await _pump(tester);
    expect(
      find.textContaining("split across members' devices"),
      findsOneWidget,
    );
    expect(find.textContaining('erasure', findRichText: true), findsNothing);
    expect(find.textContaining('shard', findRichText: true), findsNothing);
  });

  testWidgets('letting go of the pledge saves it once', (tester) async {
    await _pump(tester);
    final slider = tester.widget<HollowSlider>(find.byType(HollowSlider));
    slider.onChanged!(2);
    slider.onChangeEnd!(2);
    await tester.pumpAndSettle();
    expect(_api.pledges, [BigInt.from(2048 * _mib)]);
  });

  testWidgets('a failed pledge puts the thumb back and says why', (
    tester,
  ) async {
    _api.writeError = Exception('relay socket closed');
    await _pump(tester);
    final slider = tester.widget<HollowSlider>(find.byType(HollowSlider));
    slider.onChanged!(2);
    slider.onChangeEnd!(2);
    await tester.pumpAndSettle();
    expect(find.text('1 GB'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('an admin picks a retention from one sheet', (tester) async {
    await _pump(tester);
    await tester.ensureVisible(find.text('Files'));
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('Keep files for'), findsOneWidget);
    await tester.tap(find.text('90 days'));
    await tester.pumpAndSettle();
    expect(_api.settings['retention_files'], '90d');
    expect(_api.settings['retention_files_since'], isNotNull);
    expect(find.text('90 days'), findsOneWidget);
  });

  testWidgets('a failed retention change goes back and says why', (
    tester,
  ) async {
    _api.writeError = Exception('relay socket closed');
    await _pump(tester);
    await tester.ensureVisible(find.text('Messages'));
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('90 days'));
    await tester.pumpAndSettle();
    expect(_api.settings, isEmpty);
    expect(find.text('Forever'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a member sees the retention but cannot change it', (
    tester,
  ) async {
    await _pump(tester, role: 'member');
    expect(find.text('Only admins can change this.'), findsOneWidget);
    await tester.ensureVisible(find.text('Files'));
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('Keep files for'), findsNothing);
  });

  testWidgets("Clear removes only this server's downloads", (tester) async {
    await _pump(tester, touch: false);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear downloaded files?'), findsOneWidget);
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(_api.cleared, ['$_sid:general']);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}

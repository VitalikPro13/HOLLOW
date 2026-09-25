import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/core/services/disk_space.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/storage_dashboard_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_storage_route.dart';

import '../helpers/test_app.dart';

const _sid = 'srv_storage_test';
final _gib = BigInt.from(1024 * 1024 * 1024);

class _Api implements RustLibApi {
  Object? writeError;
  final pledges = <BigInt>[];
  final settings = <String, String>{};
  int members = 3;

  @override
  Future<crdt_api.StorageStatsFfi> crateApiCrdtGetStorageStats(
          {required String serverId}) async =>
      crdt_api.StorageStatsFfi(
        totalPledgedBytes: _gib * BigInt.from(20),
        totalUsedBytes: _gib * BigInt.from(2),
        myPledgeBytes: _gib,
        myUsedBytes: _gib ~/ BigInt.two,
        memberCount: members,
        minPledgeMb: BigInt.from(512),
      );

  @override
  Future<String> crateApiCrdtGetServerSetting(
          {required String serverId, required String key}) async =>
      settings[key] ?? '';

  @override
  Future<void> crateApiCrdtSetStoragePledge(
      {required String serverId, required BigInt pledgeBytes}) async {
    if (writeError != null) throw writeError!;
    pledges.add(pledgeBytes);
  }

  @override
  Future<void> crateApiCrdtUpdateServerSetting(
      {required String serverId,
      required String key,
      required String value}) async {
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

Future<void> _pumpPhone(WidgetTester tester, {int members = 3}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      vaultStatusProvider.overrideWith(_Vault.new),
      myRoleProvider(_sid).overrideWith((ref) async => 'owner'),
      serverMembersProvider(_sid).overrideWith((ref) async => [
            for (var i = 0; i < members; i++)
              crdt_api.MemberFfi(
                peerId: 'peer_$i',
                displayName: 'Member $i',
                role: i == 0 ? 'owner' : 'member',
                nickname: '',
                twitchUsername: '',
                labels: const [],
              ),
          ]),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const MobileStorageRoute(serverId: _sid),
    ),
  ));
  // The free-space read is real I/O.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)));
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
    _api.pledges.clear();
    _api.settings.clear();
  });

  group('free space', () {
    test('reads df -Pk on GNU and BSD alike', () {
      const gnu = 'Filesystem     1024-blocks      Used Available Capacity '
          'Mounted on\n/dev/nvme0n1p2   479595536 123456789 331724548      28% /\n';
      const mac = 'Filesystem   1024-blocks      Used Available Capacity  '
          'Mounted on\n/dev/disk3s5   971350180 612345678 350000000    64%    '
          '/System/Volumes/Data\n';
      const spaced = 'Filesystem 1024-blocks Used Available Capacity Mounted on'
          '\nmap auto_home 0 0 0 100% /System/Volumes/Data/home\n';
      expect(parseDfAvailableBytes(gnu), 331724548 * 1024);
      expect(parseDfAvailableBytes(mac), 350000000 * 1024);
      expect(parseDfAvailableBytes(spaced), 0);
      expect(parseDfAvailableBytes(''), isNull);
    });

    test('reads the volume that holds the data root, even before it exists',
        () async {
      final free = await freeBytesAt(root.path);
      expect(free, isNotNull);
      expect(free, greaterThan(0));
      final later = await freeBytesAt(
          '${root.path}${Platform.pathSeparator}not_made_yet');
      expect(later, isNotNull, reason: 'falls back to the nearest folder');
    }, skip: Platform.isWindows || Platform.isLinux || Platform.isMacOS
        ? false
        : 'desktop only');

    test('the dashboard no longer hard-codes drive C: or /', () {
      final source =
          File('lib/src/ui/dialogs/storage_dashboard_dialog.dart')
              .readAsStringSync();
      expect(source, isNot(contains('Get-PSDrive C')));
      expect(source, contains('freeBytesAt(hollowDataDir)'));
    });
  });

  testWidgets('the phone bar shows the space the server really uses',
      (tester) async {
    await _pumpPhone(tester);
    final bar = tester.widget<StorageUsageBar>(find.byType(StorageUsageBar));
    expect(bar.fraction, greaterThan(0),
        reason: 'the bar was hard-coded to empty below six members');
    expect(find.textContaining('free'), findsOneWidget);
  });

  group('saves', () {
    testWidgets('a pledge under 512 MB says why at the field', (tester) async {
      await _pumpPhone(tester, members: 7);
      await tester.tap(find.textContaining('Pledge:'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '100');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Pledge at least 512 MB.'), findsOneWidget);
      expect(_api.pledges, isEmpty);
    });

    testWidgets('a failed pledge stays open with a plain reason',
        (tester) async {
      _api.writeError = Exception('relay socket closed');
      await _pumpPhone(tester, members: 7);
      await tester.tap(find.textContaining('Pledge:'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2048');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Set storage pledge'), findsOneWidget);
      expect(find.textContaining("can't reach the relay"), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
    });

    testWidgets('a saved pledge closes and says so', (tester) async {
      await _pumpPhone(tester, members: 7);
      await tester.tap(find.textContaining('Pledge:'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2048');
      await tester.tap(find.text('Save'));
      await tester.pump();
      await tester.pump();
      expect(_api.pledges, [BigInt.from(2048) * BigInt.from(1024 * 1024)]);
      expect(find.text('Pledge saved'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a failed retention change stays open and says why',
        (tester) async {
      _api.writeError = Exception('relay socket closed');
      await _pumpPhone(tester);
      await tester.tap(find.text('Permanent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('90 days'));
      await tester.pumpAndSettle();
      expect(find.text('Message retention'), findsOneWidget);
      expect(find.textContaining("can't reach the relay"), findsOneWidget);
      expect(_api.settings, isEmpty);
    });
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/storage_section.dart';

import '../helpers/test_app.dart';

final _mib = BigInt.from(1024 * 1024);

class _Api implements RustLibApi {
  int messages = 1234;
  Object? clearError;
  int clears = 0;
  String? clearedServer;

  @override
  Future<storage_api.StorageBreakdown>
  crateApiStorageGetStorageBreakdown() async => storage_api.StorageBreakdown(
    totalDbBytes: BigInt.zero,
    totalDiskBytes: BigInt.zero,
    vaultCacheBytes: BigInt.zero,
    vaultShardBytes: BigInt.zero,
    assetBlobBytes: BigInt.zero,
    assetBlobCount: 0,
    serverMessageCount: messages,
    contexts: const [],
  );

  @override
  Future<storage_api.ClearedMessages> crateApiStorageClearServerMessages({
    String? serverId,
  }) async {
    clears++;
    clearedServer = serverId;
    if (clearError != null) throw clearError!;
    final cleared = messages;
    messages = 0;
    return storage_api.ClearedMessages(
      messages: BigInt.from(cleared),
      bytesFreed: _mib * BigInt.from(150),
    );
  }

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _api = _Api();

Future<void> _pump(WidgetTester tester, {bool touch = false}) async {
  tester.view.physicalSize = touch ? const Size(390, 844) : const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: SettingsDensity(
            touch: touch,
            child: const SettingsScrollView(
              padding: EdgeInsets.all(HollowSpacing.lg),
              page: StorageBreakdownView(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openClear(WidgetTester tester) async {
  await tester.tap(find.text('Clean up'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Clear server messages'));
  await tester.pumpAndSettle();
}

void main() {
  late Directory root;

  setUpAll(() {
    RustLib.initMock(api: _api);
    root = Directory.systemTemp.createTempSync('hollow_clear_messages_test');
    overrideHollowDataDir(root.path);
  });
  tearDownAll(() => root.deleteSync(recursive: true));
  setUp(() {
    _api.messages = 1234;
    _api.clearError = null;
    _api.clears = 0;
    _api.clearedServer = 'unset';
  });

  testWidgets('the total names the device it is on', (tester) async {
    await _pump(tester);
    expect(find.textContaining('used on this computer'), findsOneWidget);
    await _pump(tester, touch: true);
    expect(find.textContaining('used on this device'), findsOneWidget);
  });

  testWidgets('the cleanup menu offers the server messages with their count', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.text('Clean up'));
    await tester.pumpAndSettle();
    expect(find.text('Clear server messages'), findsOneWidget);
    expect(find.text('1,234 messages'), findsOneWidget);
  });

  testWidgets('the confirm warns about Archives and clears only on Clear', (
    tester,
  ) async {
    await _pump(tester);
    await _openClear(tester);
    expect(find.text('Clear server messages?'), findsOneWidget);
    expect(find.textContaining('Archives you export later'), findsOneWidget);
    expect(find.textContaining('Other members keep their copies'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_api.clears, 0, reason: 'Cancel cleared the history');

    await _openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(_api.clears, 1);
    expect(_api.clearedServer, isNull, reason: 'the global clear named a server');
    expect(
      find.text('Cleared 1,234 messages. 150 MB freed on this device.'),
      findsOneWidget,
    );
    expect(find.text('Clear server messages?'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failed clear keeps the dialog open and says why', (
    tester,
  ) async {
    _api.clearError = 'Failed to clear messages: disk I/O error';
    await _pump(tester);
    await _openClear(tester);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear server messages?'), findsOneWidget);
    expect(find.textContaining('Cleared'), findsNothing);
  });

  testWidgets('with no server messages the item is there but off', (
    tester,
  ) async {
    _api.messages = 0;
    await _pump(tester);
    await tester.tap(find.text('Clean up'));
    await tester.pumpAndSettle();
    expect(find.text('Clear server messages'), findsNothing,
        reason: 'with nothing at all to clean, the menu does not open');
  });

  testWidgets('a server clear names its server and warns about Archives', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => confirmAndClearServerMessages(
                  context,
                  ref.read(storageActionsProvider),
                  serverId: 's1',
                  serverName: 'Gaming Club',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Clear messages from Gaming Club?'), findsOneWidget);
    expect(find.textContaining('Archives you export later'), findsOneWidget);
    expect(find.textContaining('Direct messages stay'), findsNothing);
    expect(find.textContaining('every message in Gaming Club'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(_api.clearedServer, 's1');
    expect(
      find.text('Cleared 1,234 messages. 150 MB freed on this device.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
  });
}

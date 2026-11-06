import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';

import '../helpers/test_app.dart';

/// An empty channel this device cleared, or whose history here begins later
/// (a late join), never claims to be the channel's start: other members still
/// hold what came before.
class _Api implements RustLibApi {
  final cleared = <String>{};
  final later = <String>{};
  Object? readError;
  Object? laterError;

  @override
  Future<bool> crateApiStorageChannelHistoryBeginsLater({
    required String serverId,
    required String channelId,
  }) async {
    if (laterError != null) throw laterError!;
    return later.contains('$serverId/$channelId');
  }

  @override
  Future<bool> crateApiStorageChannelHistoryCleared({
    required String serverId,
    required String channelId,
  }) async {
    if (readError != null) throw readError!;
    return cleared.contains('$serverId/$channelId');
  }

  @override
  Future<storage_api.ClearedMessages> crateApiStorageClearServerMessages({
    String? serverId,
  }) async {
    cleared.add('$serverId/general');
    return storage_api.ClearedMessages(
        messages: BigInt.one, bytesFreed: BigInt.zero);
  }

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}

final _api = _Api();

const _beginning = 'This is the beginning of the channel.';
const _clearedLine = 'Older messages were cleared from this device.';
const _laterLine = "Older messages aren't on this device yet.";

Future<ProviderContainer> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: channelConversationStart('general',
              serverId: 'srv', channelId: 'general'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
      tester.element(find.byType(Scaffold)));
}

void main() {
  setUpAll(() => RustLib.initMock(api: _api));
  setUp(() {
    _api.cleared.clear();
    _api.later.clear();
    _api.readError = null;
    _api.laterError = null;
  });

  testWidgets('a channel never cleared here starts here', (tester) async {
    await _pump(tester);
    expect(find.text('Welcome to #general'), findsOneWidget);
    expect(find.text(_beginning), findsOneWidget);
    expect(find.text(_clearedLine), findsNothing);
  });

  testWidgets('a channel cleared here says so, never that it starts here',
      (tester) async {
    _api.cleared.add('srv/general');
    await _pump(tester);
    expect(find.text('Welcome to #general'), findsOneWidget);
    expect(find.text(_clearedLine), findsOneWidget);
    expect(find.text(_beginning), findsNothing);
  });

  testWidgets('a late joiner lacking older messages says they are not here yet',
      (tester) async {
    _api.later.add('srv/general');
    await _pump(tester);
    expect(find.text('Welcome to #general'), findsOneWidget);
    expect(find.text(_laterLine), findsOneWidget);
    expect(find.text(_beginning), findsNothing);
    expect(find.text(_clearedLine), findsNothing);
  });

  testWidgets('a phone shows the late joiner the same line', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _api.later.add('srv/general');
    await _pump(tester);
    expect(find.text(_laterLine), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a clear outranks a late start', (tester) async {
    _api.cleared.add('srv/general');
    _api.later.add('srv/general');
    await _pump(tester);
    expect(find.text(_clearedLine), findsOneWidget);
    expect(find.text(_laterLine), findsNothing);
  });

  testWidgets('a late-start read that fails claims nothing about the start',
      (tester) async {
    _api.laterError = 'Message store is not open';
    await _pump(tester);
    expect(find.text('Welcome to #general'), findsOneWidget);
    expect(find.text(_beginning), findsNothing);
    expect(find.text(_laterLine), findsNothing);
  });

  testWidgets('a read that fails claims nothing about the start',
      (tester) async {
    _api.readError = 'Message store is not open';
    await _pump(tester);
    expect(find.text('Welcome to #general'), findsOneWidget);
    expect(find.text(_beginning), findsNothing);
  });

  testWidgets('an open empty channel changes its line when its server is cleared',
      (tester) async {
    final container = await _pump(tester);
    expect(find.text(_beginning), findsOneWidget);
    await container
        .read(storageActionsProvider)
        .clearServerMessages(serverId: 'srv');
    await tester.pumpAndSettle();
    expect(find.text(_clearedLine), findsOneWidget);
    expect(find.text(_beginning), findsNothing);
  });
}

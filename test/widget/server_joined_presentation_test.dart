/// What a completed server join does to the screen: one made on this device opens
/// the server, one our other device made only says so, and one re-shared after a
/// loss (repair, relink, lost database) slots in silently.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => const {};

  @override
  void onServerCreated(String serverId, String name) {
    state = {...state, serverId: ServerInfo(serverId: serverId, name: name)};
  }
}

class _Strip extends ServerStripLayoutNotifier {
  @override
  void onServerCreated(String serverId) {}
}

class _Channels extends ChannelListNotifier {
  @override
  Future<void> loadForServer(String serverId) async {}
}

class _Layout extends ChannelLayoutNotifier {
  @override
  Future<void> loadForServer(String serverId) async {}
}

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final container = ProviderContainer(overrides: [
    serverListProvider.overrideWith(_Servers.new),
    serverStripLayoutProvider.overrideWith(_Strip.new),
    channelListProvider.overrideWith(_Channels.new),
    channelLayoutProvider.overrideWith(_Layout.new),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      navigatorKey: hollowNavigatorKey,
      theme: HollowThemeData.dark(),
      home: const SizedBox.expand(),
    ),
  ));
  container.read(selectedServerProvider.notifier).state = 'where-i-was';
  return container;
}

Future<void> _join(WidgetTester tester, ProviderContainer container,
    {required bool quiet, required bool fromSibling}) async {
  applyServerJoined(container.read,
      serverId: 'lounge-id', name: 'Lounge', quiet: quiet, fromSibling: fromSibling);
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a join made on this device opens the server and says so',
      (tester) async {
    final container = await _pump(tester);
    await _join(tester, container, quiet: false, fromSibling: false);

    expect(container.read(selectedServerProvider), 'lounge-id');
    expect(find.text('Joined Lounge'), findsOneWidget);
    expect(container.read(serverListProvider), contains('lounge-id'));
    await _settle(tester);
  });

  testWidgets('a join our other device made says so and leaves the screen',
      (tester) async {
    final container = await _pump(tester);
    await _join(tester, container, quiet: false, fromSibling: true);

    expect(container.read(selectedServerProvider), 'where-i-was');
    expect(find.text('Joined Lounge'), findsOneWidget);
    expect(container.read(serverListProvider), contains('lounge-id'));
    await _settle(tester);
  });

  testWidgets('a server shared back after a loss slots in silently',
      (tester) async {
    final container = await _pump(tester);
    await _join(tester, container, quiet: true, fromSibling: true);

    expect(container.read(selectedServerProvider), 'where-i-was');
    expect(find.text('Joined Lounge'), findsNothing);
    expect(container.read(serverListProvider), contains('lounge-id'));
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// #154 review L14: category names are not unique, so the desktop sidebar
/// folds a category by its place in the layout, never by its name.
class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _Api());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  testWidgets('two categories with the same name fold on their own',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final layout = layoutToJson(const [
      CategoryItem('Text'),
      ChannelItem(kChannelId1),
      CategoryItem('Text'),
      ChannelItem(kChannelId2),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        selectedServerProvider.overrideWith((_) => kServerId1),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: ChannelSidebar(
              peers: const {},
              lastMessages: const {},
              selectedPeerId: null,
              nodeStatus: NodeStatus.connected,
              onPeerSelected: (_) {},
              lastMessage: (_) => null,
              formatTime: (_) => '',
              selectedServer: testServers[kServerId1]!,
              channels: {
                kChannelId1: testChannels[kChannelId1]!,
                kChannelId2: testChannels[kChannelId2]!,
              },
              channelLayoutJson: layout,
              selectedChannelId: null,
              onChannelSelected: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('general'), findsOneWidget);
    expect(find.text('random'), findsOneWidget);

    await tester.tap(find.text('Text').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('general'), findsNothing);
    expect(find.text('random'), findsOneWidget,
        reason: 'folding the first Text category folded the second too');

    // Put it back: the fold state outlives the widget.
    await tester.tap(find.text('Text').first);
    await tester.pump(const Duration(milliseconds: 400));
  });
}

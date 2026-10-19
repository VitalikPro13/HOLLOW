// Both Enter keys act the same in a channel composer: the main key and the
// numpad's pick a highlighted @mention and send otherwise.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Every FFI call stays pending, so the pane sits in its loading state.
class _PendingApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

const _enterKeys = {
  'Enter': LogicalKeyboardKey.enter,
  'numpad Enter': LogicalKeyboardKey.numpadEnter,
};

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final channel = testChannels[kChannelId1]!;
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      selectedServerProvider.overrideWith((_) => kServerId1),
      selectedChannelProvider.overrideWith((_) => kChannelId1),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: ChannelChatPane(
          serverId: kServerId1,
          channelId: channel.channelId,
          channelName: channel.name,
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Finder get _composer => find
    .descendant(
        of: find.byType(ChannelChatPane), matching: find.byType(EditableText))
    .last;

String _text(WidgetTester tester) =>
    tester.widget<EditableText>(_composer).controller.text;

void main() {
  setUpAll(() {
    RustLib.initMock(api: _PendingApi());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  for (final MapEntry(key: label, value: key) in _enterKeys.entries) {
    testWidgets('$label picks the highlighted mention', (tester) async {
      await _pump(tester);
      await tester.enterText(_composer, '@ev');
      await tester.pump();
      expect(await tester.sendKeyEvent(key), isTrue);
      await tester.pump();
      expect(_text(tester), '@everyone ');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('$label sends from the channel composer', (tester) async {
      await _pump(tester);
      await tester.enterText(_composer, 'hello channel');
      await tester.pump();
      expect(await tester.sendKeyEvent(key), isTrue);
      await tester.pump();
      expect(_text(tester), isNot(contains('\n')));
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
}

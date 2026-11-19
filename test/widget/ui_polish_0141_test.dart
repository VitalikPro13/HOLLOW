import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// 0.14.1 UI nits: the sidebar header names a mixed list honestly, phone call
/// labels fit instead of ellipsizing, and a tooltip answers a long press on a
/// phone.
class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

Future<void> _pumpSidebar(
    WidgetTester tester, Map<String, ChannelInfo> channels) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
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
            channels: channels,
            selectedChannelId: kChannelId1,
            onChannelSelected: (_) {},
          ),
        ),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}


Widget _emoteCellLike(void Function() onMenu) => MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Center(
          // emoji_picker.dart _emoteCell: GestureDetector(onLongPressStart:
          // menu) > HollowPressable > HollowTooltip > the emote image.
          child: GestureDetector(
            onLongPressStart: (_) => onMenu(),
            child: HollowPressable(
              onTap: () {},
              semanticLabel: 'Emote x',
              child: const HollowTooltip(
                message: ':x:',
                child: SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ),
      ),
    );

const _words = ['Unmute', 'Undeafen', 'Camera', 'Share', 'Speaker', 'Leave'];

void main() {
  setUpAll(() {
    RustLib.initMock(api: _Api());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
  });

  group('sidebar header', () {
    testWidgets('a list with a voice room reads "Channels"', (tester) async {
      await _pumpSidebar(tester, testChannels);
      expect(find.text('Channels'), findsOneWidget);
      expect(find.text('Text channels'), findsNothing);
    });

    testWidgets('a text-only list keeps "Text channels"', (tester) async {
      await _pumpSidebar(tester, {
        for (final e in testChannels.entries)
          if (e.value.channelType == ChannelType.text) e.key: e.value,
      });
      expect(find.text('Text channels'), findsOneWidget);
    });
  });

  Future<void> pumpControls(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: MobileCallControlRow(controls: [
          for (final w in _words)
            MobileCallControl(icon: LucideIcons.mic, label: w, onTap: () {}),
        ]),
      ),
    ));
  }

  testWidgets('phone call labels shrink a little to fit instead of ellipsizing',
      (tester) async {
    // Test glyphs are as wide as the font size: "Undeafen" is 88 px, and a
    // slot of 85 is within the shrink the 10 px floor allows.
    await pumpControls(tester, 85.0 * _words.length + 32);
    for (final w in _words) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(w));
      expect(paragraph.didExceedMaxLines, isFalse, reason: w);
      expect(tester.getRect(find.text(w)).width, lessThanOrEqualTo(85.01),
          reason: '$w stays inside its slot');
    }
  });

  testWidgets('phone call labels never shrink under the 10 px floor',
      (tester) async {
    await pumpControls(tester, 260);
    for (final w in _words) {
      final rect = tester.getRect(find.text(w));
      final laidOut = tester.getSize(find.text(w));
      expect(rect.height, greaterThanOrEqualTo(laidOut.height * 10 / 11 - 0.01),
          reason: '$w is drawn at 10 px or more');
    }
  });

  group('no long-press tooltips on touch', () {
    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      testWidgets(
          '${platform.name}: a long press reaches the ancestor and shows no '
          'tooltip', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        var menus = 0;
        await tester.pumpWidget(_emoteCellLike(() => menus++));
        final gesture = await tester
            .startGesture(tester.getCenter(find.byType(HollowTooltip)));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 600));
        final shown = find.text(':x:').evaluate().length;
        await gesture.up();
        await tester.pump(const Duration(seconds: 2));
        final opened = menus;
        debugDefaultTargetPlatformOverride = null;
        expect(opened, 1, reason: 'the emote menu (Remove from my emotes)');
        expect(shown, 0, reason: 'tooltips are hover-only');
      });
    }

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('${platform.name}: a Material tooltip (the date picker\'s) '
          'stays hidden on a long press', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await tester.pumpWidget(MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(
            body: Center(
              child: Tooltip(
                message: 'Previous month',
                child: SizedBox(width: 40, height: 40),
              ),
            ),
          ),
        ));
        await tester.longPress(find.byType(Tooltip));
        await tester.pump(const Duration(milliseconds: 600));
        final shown = find.text('Previous month').evaluate().length;
        await tester.pump(const Duration(seconds: 3));
        debugDefaultTargetPlatformOverride = null;
        expect(shown, 0);
      });
    }
  });
}

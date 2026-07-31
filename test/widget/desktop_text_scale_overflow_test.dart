/// Desktop chrome must survive the OS text size.
///
/// `text_scale_overflow_test.dart` pins `MobileShell` at 1.5x/2.0x, but the
/// desktop shell had no equivalent — and `app.dart` deliberately applies NO
/// clamp there ("Desktop has no clamp (full OS scaling already flows
/// through)"). So a Windows user who sets Accessibility > Text size to 125%+
/// was already running Hollow at a raised text scale with nothing verifying
/// it, no in-app slider involved.
///
/// That found a real bug: `UserBar` overflowed by 36px horizontally (a bare
/// `Text` for the status word, squeezed beside the avatar and three trailing
/// icons in a 240px sidebar) and 2px vertically (name + status stacked in a
/// hard `height: 52` box). Both are fixed — this is the tripwire.
///
/// Only chrome is covered here: the fixed-size bars and panels with no room
/// to grow. Content areas scroll and are expected to honor full 2.0x.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/bottom_bar.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:hollow/src/ui/shell/member_panel.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';

import '../helpers/test_app.dart';

const _channels = <String, ChannelInfo>{
  'c1': ChannelInfo(channelId: 'c1', name: 'general'),
  'c2': ChannelInfo(
      channelId: 'c2', name: 'Voice Lounge', channelType: ChannelType.voice),
};

Widget _sidebar() => ChannelSidebar(
      peers: const {},
      lastMessages: const {},
      selectedPeerId: null,
      nodeStatus: NodeStatus.connected,
      onPeerSelected: (_) {},
      lastMessage: (_) => null,
      formatTime: (_) => '',
      selectedServer: const ServerInfo(serverId: 'srv-1', name: 'Test Server'),
      channels: _channels,
      selectedChannelId: 'c1',
    );

/// The desktop surfaces that are fixed-size chrome, so have nowhere to put
/// text that grew. `ChannelSidebar` is included because it hosts `UserBar`.
final _surfaces = <String, Widget Function()>{
  'FriendsBar': () =>
      const Align(alignment: Alignment.topCenter, child: FriendsBar()),
  'ChannelSidebar': _sidebar,
  'MemberPanel': () => const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: 240, height: 700, child: MemberPanel()),
      ),
  'BottomBar': () =>
      const Align(alignment: Alignment.bottomCenter, child: BottomBar()),
  'UserBar': () => const Align(
        alignment: Alignment.bottomLeft,
        child: SizedBox(width: 240, child: UserBar()),
      ),
};

void main() {
  // 1.0 is the baseline (a bare Text can overflow a tight row even here —
  // it did). 1.25/1.5 are ordinary Windows Accessibility steps; 2.0 is the
  // ceiling the mobile shell already honors.
  for (final scale in const [1.0, 1.25, 1.5, 2.0]) {
    for (final entry in _surfaces.entries) {
      testWidgets('${entry.key} does not overflow at ${scale}x OS text scale',
          (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // Collect overflows directly: a RenderFlex overflow paints an error
        // and reports through FlutterError, and several can fire in one pump
        // (takeException only surfaces the first).
        final overflows = <String>{};
        final prior = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.exceptionAsString().contains('overflow')) {
            overflows.add(details.exceptionAsString().split('\n').first);
          } else {
            prior?.call(details);
          }
        };

        await tester.pumpWidget(
          ProviderScope(
            overrides: hollowTestOverrides(),
            child: MaterialApp(
              theme: HollowThemeData.dark(),
              home: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: Scaffold(body: entry.value()),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        FlutterError.onError = prior;

        expect(
          overflows,
          isEmpty,
          reason: '${entry.key} overflowed at ${scale}x OS text scale:\n'
              '  ${overflows.join('\n  ')}',
        );
      });
    }
  }
}

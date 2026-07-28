/// Channel-sidebar banner header (issue #25): the header stays 48px in
/// home/DM mode and without a banner, grows when the selected server has
/// banner bytes, and keys on the banner hash so a re-upload crossfades.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/shell/channel_sidebar.dart';

import '../helpers/test_app.dart';

// 1x1 transparent PNG — Image decoding accepts it; the header render path
// doesn't care that real banners are WebP.
final Uint8List _kTinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

final String _hash = 'b' * 64;

class _SeededBannerNotifier extends ServerBannerNotifier {
  final Map<String, ServerBannerEntry> seed;
  _SeededBannerNotifier(this.seed);

  @override
  Map<String, ServerBannerEntry> build() => seed;
}

Future<void> _pump(
  WidgetTester tester, {
  ServerInfo? server,
  Map<String, ServerBannerEntry> banners = const {},
}) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        serverBannerProvider
            .overrideWith(() => _SeededBannerNotifier(banners)),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: ChannelSidebar(
            peers: const {},
            lastMessages: const {},
            selectedPeerId: null,
            nodeStatus: NodeStatus.connected,
            onPeerSelected: (_) {},
            lastMessage: (_) => null,
            formatTime: (_) => '',
            selectedServer: server,
            showUserBar: false,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  const server = ServerInfo(serverId: 'srv-1', name: 'Test Server');

  testWidgets('home mode header stays 48px', (tester) async {
    await _pump(tester);

    final header =
        find.byKey(const ValueKey('header-Direct Messages'));
    expect(header, findsOneWidget);
    expect(tester.getSize(header).height, 48);
    expect(find.byType(AnimatedGifImage), findsNothing);
  });

  testWidgets('server without banner keeps the 48px header', (tester) async {
    await _pump(tester, server: server);

    final header = find.byKey(const ValueKey('header-Test Server'));
    expect(header, findsOneWidget);
    expect(tester.getSize(header).height, 48);
  });

  testWidgets('server with a banner grows the header and renders it',
      (tester) async {
    await _pump(
      tester,
      server: server,
      banners: {
        'srv-1': ServerBannerEntry(
          bytes: _kTinyPng,
          hash: _hash,
          animated: false,
        ),
      },
    );

    // Keyed on label AND hash so a re-upload (same label) still crossfades.
    final header = find.byKey(ValueKey('header-Test Server-$_hash'));
    expect(header, findsOneWidget);
    expect(tester.getSize(header).height, 120);
    expect(find.byType(AnimatedGifImage), findsOneWidget);
  });
}

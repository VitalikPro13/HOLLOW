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
import 'package:hollow/src/theme/hollow_typography.dart';
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
  Size viewport = const Size(1000, 800),
}) async {
  tester.view.physicalSize = viewport;
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

  /// Issue #37 / #20 follow-up. The interface zoom lays the app out at
  /// `viewport / scale`, so raising it SHORTENS the sidebar column instead of
  /// just magnifying it: 1080p gives the sidebar ~905 logical px at 100% but
  /// ~401 at 200%. A flat 120px banner therefore went from 13% of the column
  /// to 30% of it, and with the voice panel stacked underneath, over half the
  /// sidebar was chrome — which is why the reporter's 200% screenshot fits
  /// three channels. The header now yields under that pressure and only then.
  group('banner header yields as the sidebar column shrinks', () {
    test('full height whenever the column can afford it', () {
      // ~905 = a 1080p sidebar at 100% zoom; 545 is the exact break-even
      // (120 / 0.22). Neither may change.
      expect(bannerHeaderHeight(905), kBannerHeaderHeight);
      expect(bannerHeaderHeight(600), kBannerHeaderHeight);
      expect(bannerHeaderHeight(kBannerHeaderHeight / 0.22), kBannerHeaderHeight);
    });

    test('yields proportionally once the column is short', () {
      // ~401 = a 1080p sidebar at 200% zoom, the reported case.
      final at200 = bannerHeaderHeight(401);
      expect(at200, lessThan(kBannerHeaderHeight));
      expect(at200, closeTo(401 * 0.22, 0.01));
    });

    test('never shrinks past the floor, and survives junk input', () {
      // The server name + action icons still have to read.
      expect(bannerHeaderHeight(200), kBannerHeaderMinHeight);
      expect(bannerHeaderHeight(1), kBannerHeaderMinHeight);
      // An unbounded/degenerate column must not produce NaN or 0.
      expect(bannerHeaderHeight(double.infinity), kBannerHeaderHeight);
      expect(bannerHeaderHeight(0), kBannerHeaderHeight);
      expect(bannerHeaderHeight(-5), kBannerHeaderHeight);
    });

    testWidgets('a tall sidebar still renders the full 120px header',
        (tester) async {
      await _pump(
        tester,
        server: server,
        viewport: const Size(1000, 800),
        banners: {
          'srv-1': ServerBannerEntry(
              bytes: _kTinyPng, hash: _hash, animated: false),
        },
      );

      final header = find.byKey(ValueKey('header-Test Server-$_hash'));
      expect(tester.getSize(header).height, kBannerHeaderHeight);
    });

    testWidgets('a zoom-shortened sidebar hands the space to the channel list',
        (tester) async {
      // 960x420 ≈ what 1080p looks like below a 200% interface scale.
      await _pump(
        tester,
        server: server,
        viewport: const Size(960, 420),
        banners: {
          'srv-1': ServerBannerEntry(
              bytes: _kTinyPng, hash: _hash, animated: false),
        },
      );

      final header = find.byKey(ValueKey('header-Test Server-$_hash'));
      final height = tester.getSize(header).height;
      expect(height, lessThan(kBannerHeaderHeight),
          reason: 'the banner must yield when the column is short');
      expect(height, greaterThanOrEqualTo(kBannerHeaderMinHeight));

      // Yielding is pointless if it costs a layout error.
      expect(tester.takeException(), isNull);
    });

    testWidgets('chrome never takes more of the column than the list',
        (tester) async {
      // The actual regression to guard: at 200% the fixed 120px banner was
      // 30% of the sidebar, and stacked with the voice panel it left the
      // channel list a minority of its own column.
      await _pump(
        tester,
        server: server,
        viewport: const Size(960, 420),
        banners: {
          'srv-1': ServerBannerEntry(
              bytes: _kTinyPng, hash: _hash, animated: false),
        },
      );

      final sidebar = tester.getSize(find.byType(ChannelSidebar));
      final headerHeight = tester
          .getSize(find.byKey(ValueKey('header-Test Server-$_hash')))
          .height;

      expect(headerHeight / sidebar.height, lessThan(0.25),
          reason: 'the banner must stay a minority slice of a short sidebar; '
              'a flat 120 was 30% of a 200%-zoom column');
    });
  });

  /// Issue #37: "the channel list on the left icons and names are ever so
  /// tiny". Voice-participant rows were the smallest thing in the app — an
  /// 18px avatar and 11px `caption` text sitting directly under a 14px
  /// channel name, next to 28px/12px member rows. The interface zoom cannot
  /// correct that, because it multiplies every size by the same factor: an
  /// 11-next-to-14 stays 11-next-to-14 at 200%. These pin the RATIO so the
  /// values can't be quietly tidied back down.
  group('voice participant rows stay legible next to their neighbours', () {
    test('avatar is in the same family as other person rows', () {
      // Member panel and chat both use 28. Participant rows are nested
      // sub-rows so they may be smaller — but not half the size.
      expect(kVoiceParticipantAvatarSize, greaterThanOrEqualTo(22));
      expect(kVoiceParticipantAvatarSize, lessThanOrEqualTo(28));
    });

    test('status glyphs did not stay at the old 12px', () {
      expect(kVoiceParticipantIconSize, greaterThanOrEqualTo(14));
    });

    test('the name style is not the app-wide smallest', () {
      // The row now uses `label`; `caption` is what made it disappear.
      expect(HollowTypography.label.fontSize, greaterThan(
          HollowTypography.caption.fontSize!));
      expect(HollowTypography.label.fontSize, greaterThanOrEqualTo(12));
    });
  });
}

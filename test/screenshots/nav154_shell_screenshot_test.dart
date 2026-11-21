import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_chats_tab.dart';

import '../helpers/mobile_servers_fixture.dart';
import '../helpers/test_app.dart';

/// #154 shell renders at 390x844, dark and light: the Servers tab (dock order,
/// a folder, badges, a voice room, muted, a parked join), Chats with the
/// Archive icon in its header, the Archive page, and the empty Servers tab.
/// Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/nav154.
class _NoServers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => const {};
}

class _NoPending extends PendingJoinsNotifier {
  @override
  Map<String, PendingJoinInfo> build() => const {};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}nav154';

  setUpAll(() async {
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
              ? 'GeistMono'
              : null;
      if (family == null) continue;
      families
          .putIfAbsent(family, () => [])
          .add(ByteData.view(File(face.path).readAsBytesSync().buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      final image = await layer.toImage(view.paintBounds);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
    });
  }

  Future<void> pumpShell(WidgetTester tester,
      {required bool light,
      List<Override> extra = const [],
      double textScale = 1.0,
      double width = 390}) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        connectionStatusProvider.overrideWith(TestRelayStatus.new),
        archiveDmListProvider.overrideWith((ref) async => const []),
        archiveChannelListProvider.overrideWith((ref) async => const []),
        ...extra,
      ]),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const MobileShell(),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 3));
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
        of: find.byType(MobileNavBar), matching: find.text(label)));
    await tester.pumpAndSettle();
  }

  for (final light in [false, true]) {
    final tag = light ? 'light' : 'dark';

    testWidgets('servers tab $tag', (tester) async {
      await pumpShell(tester, light: light, extra: mobileServersFixture());
      await tab(tester, 'Servers');
      await capture(tester, 'servers_$tag');
    });

    testWidgets('chats tab $tag', (tester) async {
      await pumpShell(tester, light: light, extra: mobileServersFixture());
      await capture(tester, 'chats_$tag');
    });

    testWidgets('archive page $tag', (tester) async {
      await pumpShell(tester, light: light);
      await tester.tap(find.descendant(
          of: find.byType(MobileChatsTab),
          matching: find.bySemanticsLabel('Archive')));
      await tester.pumpAndSettle();
      await capture(tester, 'archive_$tag');
    });

    testWidgets('servers empty $tag', (tester) async {
      await pumpShell(tester, light: light, extra: [
        serverListProvider.overrideWith(_NoServers.new),
        pendingJoinsProvider.overrideWith(_NoPending.new),
      ]);
      await tab(tester, 'Servers');
      await capture(tester, 'servers_empty_$tag');
    });
  }

  testWidgets('servers tab at 2x text', (tester) async {
    await pumpShell(tester,
        light: false, extra: mobileServersFixture(), textScale: 2.0);
    await tab(tester, 'Servers');
    await capture(tester, 'servers_text2x_dark');
  });

  // Review L1: at 320 the greeting sheds the name instead of cutting itself.
  testWidgets('chats tab at 320 wide', (tester) async {
    await pumpShell(tester,
        light: false, extra: mobileServersFixture(), width: 320);
    await capture(tester, 'chats_320_dark');
  });

  // Review M1: the call bar docks between the tab and the nav bar.
  for (final label in ['Servers', 'Chats']) {
    testWidgets('call docked on $label', (tester) async {
      await pumpShell(tester, light: false, extra: [
        ...mobileServersFixture(),
        voiceChannelProvider.overrideWith(() => _InRoom()),
      ]);
      if (label == 'Servers') await tab(tester, label);
      await capture(tester, 'call_docked_${label.toLowerCase()}_dark');
    });
  }
}

/// In Synth Lab's Lounge with the fixture's three people.
class _InRoom extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState(
        currentServerId: kSrvAlpha,
        currentChannelId: kSrvLoungeId,
        currentChannelName: 'Lounge',
        participants: {
          kSrvAlpha: {
            kSrvLoungeId: {'peer_mira', 'peer_juno', 'peer_kai'},
          },
        },
      );
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/dialogs/relay_denied_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// t14-deny: the channel pane and phone page with the server refused by the relay
/// (After) and carried (Before), plus the refused-login dialog.
/// Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/relay_denied.
class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}relay_denied';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
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
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
    });
  }

  Future<void> shoot(WidgetTester tester, String name,
      {required bool phone, required bool denied, bool light = false, double width = 0}) async {
    final w = width > 0 ? width : (phone ? 375.0 : 1280.0);
    tester.view.physicalSize = Size(w, phone ? 760 : 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final channel = testChannels[kChannelId1]!;
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: hollowTestOverrides(extra: [
          selectedServerProvider.overrideWith((_) => kServerId1),
          selectedChannelProvider.overrideWith((_) => kChannelId1),
          relayDeniedServersProvider.overrideWith(
              (_) => denied ? {kServerId1.toLowerCase()} : <String>{}),
        ]),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          home: phone
              ? MobileChatRoute(
                  serverId: kServerId1,
                  channelId: channel.channelId,
                  channelName: channel.name,
                )
              : Scaffold(
                  body: ChannelChatPane(
                    serverId: kServerId1,
                    channelId: channel.channelId,
                    channelName: channel.name,
                  ),
                ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await capture(tester, name);
  }

  for (final denied in [false, true]) {
    final tag = denied ? 'after' : 'before';
    testWidgets('desktop $tag', (t) => shoot(t, 'desktop_$tag', phone: false, denied: denied));
    testWidgets('desktop narrow $tag',
        (t) => shoot(t, 'desktop_800_$tag', phone: false, denied: denied, width: 800));
    testWidgets('phone $tag', (t) => shoot(t, 'phone_$tag', phone: true, denied: denied));
    testWidgets('phone light $tag',
        (t) => shoot(t, 'phone_light_$tag', phone: true, denied: denied, light: true));
    testWidgets('phone 320 $tag',
        (t) => shoot(t, 'phone_320_$tag', phone: true, denied: denied, width: 320));
  }

  for (final kind in ['account_denied', 'network_denied']) {
    testWidgets('dialog $kind', (tester) async {
      tester.view.physicalSize = const Size(900, 500);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(
        key: shotKey,
        child: ProviderScope(
          overrides: hollowTestOverrides(),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(body: Center(child: RelayDeniedDialog(kind: kind))),
          ),
        ),
      ));
      await tester.pump();
      await capture(tester, 'dialog_$kind');
    });
  }
}

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
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/relay_denied_notice.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/dialogs/relay_denied_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// t14-deny at large text: the notice, the refused-login dialog through
/// showHollowDialog on a phone, and the Terms under a self-hosted relay's warning.
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


  void scale(WidgetTester t, double v) {
    t.platformDispatcher.textScaleFactorTestValue = v;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  }
  for (final v in [1.5, 2.0]) {
    // The phone page's own header overflows at x2.0 (not this notice), so the whole
    // page is shot at x1.5 and the notice alone at both.
    if (v == 1.5) {
      testWidgets('phone 320 x$v', (t) async { scale(t, v); await shoot(t, 'r_phone_320_x$v', phone: true, denied: true, width: 320); });
      testWidgets('phone 375 x$v', (t) async { scale(t, v); await shoot(t, 'r_phone_375_x$v', phone: true, denied: true); });
    }
    testWidgets('notice phone 320 x$v', (tester) async {
      scale(tester, v);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(key: shotKey, child: ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: HollowThemeData.dark(),
          home: const Scaffold(body: Align(alignment: Alignment.bottomCenter,
            child: RelayDeniedNotice(serverId: 'abc', touch: true)))))));
      await tester.pump();
      await capture(tester, 'notice_phone_320_x$v');
    });
    testWidgets('desktop 800 x$v', (t) async { scale(t, v); await shoot(t, 'r_desktop_800_x$v', phone: false, denied: true, width: 800); });
    testWidgets('desktop 1280 x$v', (t) async { scale(t, v); await shoot(t, 'r_desktop_1280_x$v', phone: false, denied: true); });
    testWidgets('meeting notice phone x$v', (tester) async {
      scale(tester, v);
      tester.view.physicalSize = const Size(320, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(key: shotKey, child: ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: HollowThemeData.light(),
          home: const Scaffold(body: Align(alignment: Alignment.bottomCenter,
            child: RelayDeniedNotice(serverId: 'conf:abc', meeting: true, touch: true)))))));
      await tester.pump();
      await capture(tester, 'r_meeting_phone_light_x$v');
    });
    testWidgets('dialog phone x$v', (tester) async {
      scale(tester, v);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(key: shotKey, child: ProviderScope(
        overrides: hollowTestOverrides(),
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: HollowThemeData.dark(),
          home: const Scaffold(body: SizedBox.expand())))));
      await tester.pump();
      showHollowDialog<void>(context: tester.element(find.byType(Scaffold)),
          builder: (_) => const RelayDeniedDialog(kind: 'network_denied', touch: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await capture(tester, 'r_dialog_phone_x$v');
    });
  }

  for (final (name, phone, v) in [
    ('terms_foreign_phone_320_x2.0', true, 2.0),
    ('terms_foreign_desktop', false, 1.0),
  ]) {
    testWidgets(name, (tester) async {
      scale(tester, v);
      tester.view.physicalSize = phone ? const Size(320, 640) : const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(RepaintBoundary(key: shotKey, child: ProviderScope(
        overrides: hollowTestOverrides(),
        child: ProviderScope(
          overrides: [relayDomainProvider.overrideWith(() => _Domain('relay.example.org'))],
          child: MaterialApp(debugShowCheckedModeBanner: false, theme: HollowThemeData.dark(),
            home: const Scaffold(body: SizedBox.expand()))))));
      await tester.pump();
      await tester.runAsync(() async {
        showRelayTerms(tester.element(find.byType(Scaffold)), 'relay.example.org', touch: phone);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await capture(tester, name);
    });
  }
}

class _Domain extends RelayDomainNotifier {
  final String domain;

  _Domain(this.domain);

  @override
  String build() => domain;
}

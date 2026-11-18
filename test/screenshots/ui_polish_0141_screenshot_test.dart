import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/profile_identity_column.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// 0.14.1 UI defects: the phone DM header's verified mark, the "Their number"
/// field, and the profile sheet and card without a banner.
///
/// Output: $HOLLOW_SHOT_DIR/ui_polish_0141, else
/// build/ui_screenshots/ui_polish_0141. With HOLLOW_SHOT_BEFORE pointing at an
/// earlier run's folder, the last test writes before|after sheets.
class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
      null;

  @override
  Future<Uint8List?> crateApiStorageGetBanner({required String peerId}) async =>
      null;

  @override
  Future<String> crateApiVerificationSafetyNumberWith(
          {required String peerId}) async =>
      '052811639472018465520937715046389120475663308217495036128874';

  @override
  String crateApiVerificationFormatSafetyNumber({required String number}) => [
        for (var i = 0; i < number.length; i += 5) number.substring(i, i + 5)
      ].join(' ');

  @override
  bool crateApiVerificationSafetyNumbersMatch(
          {required String expected, required String provided}) =>
      expected == provided.replaceAll(RegExp(r'\D'), '');

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

class _Verified extends VerifiedPeersNotifier {
  @override
  Set<String> build() => {kFriendPeerId1};
}

const _vip = crdt_api.LabelFfi(
    labelId: 'l1', name: 'VIP', color: '#8B5CF6', access: false);

void main() {
  const shotKey = Key('screenshot-boundary');
  final root = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}/build/ui_screenshots';
  final outDir = '$root/ui_polish_0141';

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
      final image = await boundary.toImage(pixelRatio: 2.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('$outDir/$name.png')..parent.createSync(recursive: true);
      file.writeAsBytesSync(data!.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  Future<GlobalKey<NavigatorState>> pumpHost(
      WidgetTester tester, Size size, Widget home) async {
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        connectionStatusProvider.overrideWith(TestRelayStatus.new),
        verifiedPeersProvider.overrideWith(_Verified.new),
      ]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          navigatorKey: nav,
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: home,
        ),
      ),
    ));
    await tester.pump();
    return nav;
  }

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('dm_header', (tester) async {
    final nav = await pumpHost(
        tester, const Size(390, 160), const Scaffold(body: SizedBox()));
    unawaited(nav.currentState!.push(hollowMobileRoute<void>(
      settings: const RouteSettings(name: MobileChatRoute.routeName),
      builder: (_) => const MobileChatRoute(peerId: kFriendPeerId1),
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await capture(tester, 'dm_header');
    await done(tester);
  });

  testWidgets('verify_their_number', (tester) async {
    // The narrowest phone, where a pasted number wraps to three lines.
    await pumpHost(tester, const Size(320, 760),
        const MobileVerifyContactRoute(peerId: kFriendPeerId1));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
        find.byType(TextField),
        '05281 16394 72018 46552 09377 15046 '
        '38912 04756 63308 21749 50361 28874');
    await tester.pump(const Duration(milliseconds: 300));
    await capture(tester, 'verify_their_number');
    await done(tester);
  });

  testWidgets('profile_sheet', (tester) async {
    await pumpHost(
      tester,
      const Size(390, 560),
      Builder(builder: (context) {
        final hollow = HollowTheme.of(context);
        return Scaffold(
          backgroundColor: hollow.overlay,
          body: const Align(
            alignment: Alignment.topCenter,
            child: MobileProfileSheet(
                peerId: kFriendPeerId1, role: 'member', labels: [_vip]),
          ),
        );
      }),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await capture(tester, 'profile_sheet');
    await done(tester);
  });

  testWidgets('profile_card', (tester) async {
    await pumpHost(
      tester,
      const Size(340, 460),
      Builder(builder: (context) {
        final hollow = HollowTheme.of(context);
        return Scaffold(
          backgroundColor: hollow.background,
          body: Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: kProfileCompactWidth,
              margin: const EdgeInsets.only(top: 20),
              color: hollow.overlay,
              child: ProfileIdentityColumn(
                width: kProfileCompactWidth,
                peerId: kFriendPeerId1,
                role: 'member',
                labels: const [_vip],
                density: ProfileCardDensity.compact,
                dismissHost: () {},
                onExpand: () {},
              ),
            ),
          ),
        );
      }),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await capture(tester, 'profile_card');
    await done(tester);
  });

  final before = Platform.environment['HOLLOW_SHOT_BEFORE'];
  if (before != null) {
    testWidgets('before and after', (tester) async {
      await tester.runAsync(() async {
        Future<ui.Image> load(String dir, String name) async {
          final codec = await ui.instantiateImageCodec(
              File('$dir/$name.png').readAsBytesSync());
          return (await codec.getNextFrame()).image;
        }

        for (final name in [
          'dm_header',
          'verify_their_number',
          'profile_sheet',
          'profile_card',
        ]) {
          final a = await load(before, name);
          final b = await load(outDir, name);
          const gap = 24.0;
          final w = a.width + gap + b.width;
          final h = a.height > b.height ? a.height : b.height;
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawRect(
              Rect.fromLTWH(0, 0, w, h.toDouble()),
              Paint()
                ..color = const Color(0xFFFF00FF)); // design-ignore: test image backdrop, a seam no theme uses
          canvas.drawImage(a, Offset.zero, Paint());
          canvas.drawImage(b, Offset(a.width + gap, 0), Paint());
          final out = await recorder.endRecording().toImage(w.round(), h);
          final data = await out.toByteData(format: ui.ImageByteFormat.png);
          File('$outDir/before_after_$name.png')
              .writeAsBytesSync(data!.buffer.asUint8List());
        }
      });
    });
  }
}

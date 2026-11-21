import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/access_key_full_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_connection_indicator.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';

import '../helpers/test_app.dart';

/// #153 before and after: the status while the relay refuses a full access key, the
/// notice it opens and the key prompt with Cancel, desktop and phone, dark.
///
/// Output: $HOLLOW_SHOT_DIR/access_key_full, else build/ui_screenshots/access_key_full.
class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _desktop = Size(1440, 900);
const _phone = Size(390, 844);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir =
      '${Platform.environment['HOLLOW_SHOT_DIR'] ?? '${Directory.current.path}${sep}build${sep}ui_screenshots'}'
      '${sep}access_key_full';

  setUpAll(() async {
    RustLib.initMock(api: _Api());
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

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  late BuildContext host;

  Future<void> pump(WidgetTester tester, Size size, bool full) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final phone = size == _phone;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        connectionStatusProvider.overrideWith(
            () => TestRelayStatus(RelayConnectionStatus.disconnected)),
        relayKeyFullProvider.overrideWith((ref) => full),
      ]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Builder(builder: (context) {
              host = context;
              return phone
                  ? const Stack(children: [MobileConnectionIndicator()])
                  : const Align(
                      alignment: Alignment.bottomLeft,
                      child: SizedBox(width: 240, child: UserBar()),
                    );
            }),
          ),
        ),
      ),
    ));
    await tester.pump(kConnectionIndicatorDelay);
    await settle(tester);
  }

  for (final (label, size) in [('desktop', _desktop), ('phone', _phone)]) {
    for (final full in [false, true]) {
      testWidgets('status ${full ? 'after' : 'before'} $label', (tester) async {
        await pump(tester, size, full);
        await capture(tester, 'status_${full ? 'after' : 'before'}_$label');
      });
    }
    testWidgets('notice $label', (tester) async {
      await pump(tester, size, true);
      showAccessKeyFull(host);
      await settle(tester);
      await capture(tester, 'notice_$label');
    });
    testWidgets('key prompt with cancel $label', (tester) async {
      await pump(tester, size, true);
      unawaited(showLicenseKeyDialog(host, cancellable: true));
      await settle(tester);
      await capture(tester, 'prompt_$label');
    });
  }
}

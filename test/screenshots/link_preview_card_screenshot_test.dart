import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/link_preview_card.dart';

/// Screenshot harness for the large (social-post) link preview card.
///
/// It exists because the card's height problem is invisible in source: the
/// media area was laid out at the source aspect across the full card width,
/// which reads fine for 16:9 and turns a 9:16 reel poster into a ~700px
/// monolith. Rendering the shapes side by side is the only way to judge the
/// fit rule, so this pumps one card per aspect and writes PNGs.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
/// Writing is best-effort — an unwritable dir never fails the suite. The
/// height ASSERTIONS below are the real regression guard; the PNGs are for
/// eyeballing polish.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shotKey = Key('screenshot-boundary');

  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    try {
      final segoe = File(r'C:\Windows\Fonts\segoeui.ttf');
      if (segoe.existsSync()) {
        final bytes = segoe.readAsBytesSync();
        for (final family in ['FlutterTest', 'Ahem', 'Roboto']) {
          final l = FontLoader(family)
            ..addFont(Future.value(ByteData.view(bytes.buffer)));
          await l.load();
        }
      }
    } catch (_) {/* screenshots fall back to block glyphs */}
  });

  /// A PNG of the given pixel size with a diagonal, so the poster's shape and
  /// orientation are unmistakable in the capture. `Image.memory` decodes by
  /// content, not by the field name, so a PNG stands in for the wire's WebP.
  Future<Uint8List> posterPng(int w, int h, Color color) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = color,
    );
    canvas.drawLine(
      Offset.zero,
      Offset(w.toDouble(), h.toDouble()),
      Paint()
        ..color = Colors.white70
        ..strokeWidth = 6,
    );
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  network_api.LinkPreviewRef makePreview({
    required String title,
    required String domain,
    required int w,
    required int h,
    required String b64,
    String? videoUrl,
  }) {
    return network_api.LinkPreviewRef(
      url: 'https://$domain/p/example',
      title: title,
      description:
          'A post body long enough to occupy a couple of lines under the '
          'media, so the card is judged the way it actually appears.',
      domain: domain,
      siteName: domain,
      thumbWebpB64: b64,
      thumbW: w,
      thumbH: h,
      kind: 'large',
      author: 'Someone (@someone)',
      videoUrl: videoUrl,
    );
  }

  testWidgets('large card fits tall media instead of stretching it',
      (tester) async {
    tester.view.physicalSize = const Size(560, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    late final Uint8List wide;
    late final Uint8List portrait;
    late final Uint8List reel;
    await tester.runAsync(() async {
      wide = await posterPng(640, 360, const Color(0xFF2B6CB0)); // 16:9
      portrait = await posterPng(400, 500, const Color(0xFF9B2C6F)); // 4:5
      reel = await posterPng(360, 640, const Color(0xFF2F855A)); // 9:16
    });

    final cards = <String, network_api.LinkPreviewRef>{
      'wide': makePreview(
        title: 'A 16:9 video thumbnail',
        domain: 'youtube.com',
        w: 640,
        h: 360,
        b64: base64Encode(wide),
        videoUrl: 'https://youtube.com/watch?v=x',
      ),
      'portrait': makePreview(
        title: 'A 4:5 photo post',
        domain: 'instagram.com',
        w: 400,
        h: 500,
        b64: base64Encode(portrait),
      ),
      'reel': makePreview(
        title: 'A 9:16 reel',
        domain: 'instagram.com',
        w: 360,
        h: 640,
        b64: base64Encode(reel),
        videoUrl: 'https://instagram.com/reel/x',
      ),
    };

    final tree = ProviderScope(
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final entry in cards.entries) ...[
                    LinkPreviewCard(
                      key: ValueKey(entry.key),
                      preview: entry.value,
                      messageId: entry.key,
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // The pump has to happen inside `runAsync` or the PNG codecs never run and
    // every poster falls through to `errorBuilder` — which still lays out the
    // right BOX, so the heights would pass while the capture showed blanks.
    await tester.runAsync(() async {
      await tester.pumpWidget(tree);
      for (final bytes in [wide, portrait, reel]) {
        await precacheImage(MemoryImage(bytes), tester.element(find.byKey(shotKey)));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    double cardHeight(String key) =>
        tester.getSize(find.byKey(ValueKey(key))).height;

    final wideH = cardHeight('wide');
    final portraitH = cardHeight('portrait');
    final reelH = cardHeight('reel');
    debugPrint('[card heights] wide=$wideH portrait=$portraitH reel=$reelH');

    // The whole point: a portrait card must not tower over a landscape one.
    // Before the fit rule a 9:16 poster alone was ~670px against 16:9's ~225.
    expect(reelH, lessThan(wideH * 2.2),
        reason: 'a reel card must not dwarf a 16:9 card');
    expect(portraitH, lessThan(wideH * 2.2),
        reason: 'a portrait photo card must not dwarf a 16:9 card');

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      try {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data == null) return;
        final file = File(
            '$outDir${Platform.pathSeparator}link_preview_aspects.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('[screenshot] wrote ${file.path}');
      } catch (e) {
        debugPrint('[screenshot] skipped: $e');
      }
    });
  });
}

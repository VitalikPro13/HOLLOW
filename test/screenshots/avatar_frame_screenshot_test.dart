import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/avatar_frame.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/speaking_border.dart';

/// Screenshot harness for avatar frames (issue #54).
///
/// The widget tests assert the GEOMETRY - that the box is 1.33x, centred, and
/// costs the layout nothing. This is where the result gets judged by eye, in
/// both themes and at every size [HollowAvatar] is really used at, for the
/// one case a driven app cannot stage: UPLOADED ART. The picker's upload path
/// goes through a native file dialog, so the probe can only reach the
/// procedural built-ins.
///
/// The art here is drawn in-process rather than checked in as a fixture, so
/// what it exercises is legible: an opaque ring that hugs the avatar, corner
/// blobs that run to the very edge of the 1.33 box (the overhang), and a
/// fully transparent middle (the authoring gate's whole point).
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
/// Writing is best-effort - an unwritable dir never fails the suite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shotKey = Key('screenshot-boundary');
  const peer = 'peer_frame_shot_00001';
  final artId = 'c' * 64;
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
    } catch (_) {/* falls back to block glyphs */}
  });

  tearDown(() => AvatarFrameCache.instance.clearForTest());

  /// A 128x128 frame: a laurel-ish ring around where the avatar sits, two
  /// blobs pushed into opposite corners so the overhang is visible, and
  /// nothing at all in the middle.
  Future<Uint8List> paintArt() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const dim = 128.0;
    // The avatar occupies the middle 1/1.33 of the box.
    const inset = dim * (kFrameScale - 1) / 2 / kFrameScale;
    const avatar = Rect.fromLTWH(inset, inset, dim - inset * 2, dim - inset * 2);

    canvas.drawRRect(
      RRect.fromRectAndRadius(avatar.inflate(3), const Radius.circular(14)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFC24D), Color(0xFFFF5EA8)],
        ).createShader(const Rect.fromLTWH(0, 0, dim, dim)),
    );
    // Corner art that runs right to the edge of the box: the thing the fixed
    // box exists to bound.
    canvas.drawCircle(const Offset(14, 14), 14, Paint()..color = const Color(0xFF7BE0FF));
    canvas.drawCircle(
        const Offset(dim - 12, dim - 12), 12, Paint()..color = const Color(0xFFB07BFF));

    final picture = recorder.endRecording();
    final image = await picture.toImage(dim.toInt(), dim.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return data!.buffer.asUint8List();
  }

  Widget labelled(String label, Widget child) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 40, child: Center(child: child)),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 9)),
        ],
      );

  Future<void> shoot(WidgetTester tester,
      {required ThemeData theme, required String name}) async {
    tester.view.physicalSize = const Size(760, 540);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Uint8List art;
    await tester.runAsync(() async => art = await paintArt());

    Widget content() => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('uploaded art, every size HollowAvatar is used at'),
              const SizedBox(height: 20),
              Row(
                children: [
                  for (final size in [24.0, 32.0, 36.0, 48.0, 56.0, 72.0])
                    Padding(
                      padding: const EdgeInsets.only(right: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 80,
                            child: Center(
                              child: HollowAvatar(
                                  peerId: peer, size: size, frameId: artId),
                            ),
                          ),
                          Text('${size.toInt()}px',
                              style: const TextStyle(fontSize: 9)),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              // WHY call avatars suppress the frame. Read this row left to
              // right: "quiet, teal frame" and "speaking, no frame" are the
              // same picture. A decoration that can impersonate a functional
              // cue loses, so the call surfaces pass frameId: ''. Kept here
              // as the evidence for that call.
              const Text('why call avatars drop the frame (4 and 5 match)'),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final entry in [
                    ('quiet, art', false, artId),
                    ('speaking, art', true, artId),
                    ('quiet, teal', false, 'b:168'),
                    ('speaking, teal', true, 'b:168'),
                    ('speaking, none', true, ''),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 20),
                      child: labelled(
                        entry.$1,
                        SpeakingBorder(
                          isSpeaking: entry.$2,
                          child: HollowAvatar(
                              peerId: peer, size: 36, frameId: entry.$3),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('built-in colours, and a bare avatar for comparison'),
              const SizedBox(height: 12),
              Row(
                children: [
                  for (final id in ['', 'b:0', 'b:45', 'b:140', 'b:168', 'b:250', 'b:320'])
                    Padding(
                      padding: const EdgeInsets.only(right: 22),
                      child: labelled(
                        id.isEmpty ? 'none' : id,
                        HollowAvatar(peerId: peer, size: 36, frameId: id),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          avatarFrameProvider.overrideWith(() => _SeededFrames({artId: art})),
        ],
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Scaffold(body: content()),
          ),
        ),
      ),
    );
    // The art decode is a real async image decode: it needs the real event
    // loop, then a frame to paint into.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump();
    await tester.pump();

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      try {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data == null) return;
        final file = File('$outDir${Platform.pathSeparator}$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('[screenshot] wrote ${file.path}');
      } catch (e) {
        debugPrint('[screenshot] skipped: $e');
      }
    });
  }

  testWidgets('avatar frames — dark', (tester) async {
    await shoot(tester, theme: HollowThemeData.dark(), name: 'avatar_frames_dark');
    // Six art sizes plus six built-ins; the bare avatar draws no frame.
    expect(find.byType(AvatarFrame), findsNWidgets(16));
    // One decoded still shared by all six art avatars, which is the whole
    // point of the cache.
    expect(AvatarFrameCache.instance.stillCount, 1);
  });

  testWidgets('avatar frames — light', (tester) async {
    await shoot(tester,
        theme: HollowThemeData.light(), name: 'avatar_frames_light');
    expect(find.byType(AvatarFrame), findsNWidgets(16));
  });
}

class _SeededFrames extends AvatarFrameNotifier {
  final Map<String, Uint8List> art;
  _SeededFrames(this.art);

  @override
  Map<String, Uint8List> build() => art;
}

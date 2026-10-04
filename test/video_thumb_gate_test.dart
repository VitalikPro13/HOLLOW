/// A video someone else sent is never handed to the bundled ffmpeg before the
/// user opens it (audit C-FILES-02).
///
/// A received video lands on disk with no interaction (anything under the
/// auto-download threshold does), and the bubble used to cut its own poster
/// frame on the first build. That is ffmpeg demuxing and decoding a stranger's
/// container with nobody having asked. The bubble now shows the poster the
/// sender shipped in the file card, and only a tap on play or open lets our
/// own ffmpeg near the bytes. Our own videos keep their local poster.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/video_message_bubble.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:visibility_detector/visibility_detector.dart';

/// The head of an mp4: what the at-rest read hands ffmpeg's stdin.
final Uint8List _mp4Head = Uint8List.fromList(<int>[
  0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, // ftyp
  0x69, 0x73, 0x6F, 0x6D, 0x00, 0x00, 0x02, 0x00,
  0x69, 0x73, 0x6F, 0x6D, 0x6D, 0x70, 0x34, 0x31,
]);

void main() {
  late Directory root;
  late List<List<String>> ffmpegRuns;

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    root = Directory.systemTemp.createTempSync('hollow_video_gate');
    overrideHollowDataDir(root.path);
    ffmpegRuns = <List<String>>[];
    VideoThumbnailService.debugFfmpegPath = 'ffmpeg';
    VideoThumbnailService.debugStartProcess = (exe, args) async {
      ffmpegRuns.add(args);
      throw const ProcessException('ffmpeg', <String>[], 'stubbed in tests');
    };
    AtRest.debugRead = (_) async => _mp4Head;
  });

  tearDown(() {
    VideoThumbnailService.debugFfmpegPath = null;
    VideoThumbnailService.debugStartProcess = null;
    AtRest.debugRead = null;
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A downloaded attachment: ciphertext on disk under the data root, which
  /// is exactly what the auto-download leaves behind.
  String videoOnDisk(String fileId) {
    final files = Directory('${root.path}${Platform.pathSeparator}files')
      ..createSync(recursive: true);
    final path = '${files.path}${Platform.pathSeparator}$fileId.mp4';
    File(path).writeAsBytesSync(<int>[0x48, 0x46, 0x45, 0x31]);
    return path;
  }

  FileAttachment video(String path) => FileAttachment(
        fileId: 'vid-under-test',
        fileName: 'clip.mp4',
        fileExt: 'mp4',
        mimeType: 'video/mp4',
        sizeBytes: 1024,
        isImage: false,
        width: 320,
        height: 180,
        totalChunks: 1,
        chunksReceived: 1,
        isComplete: true,
        diskPath: path,
      );

  Future<void> pumpBubble(
    WidgetTester tester,
    FileAttachment att, {
    required bool isMine,
  }) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: VideoMessageBubble(attachment: att, isMine: isMine),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> drain(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('a_received_video_is_not_decoded_before_a_tap', (tester) async {
    await pumpBubble(tester, video(videoOnDisk('received')), isMine: false);

    expect(ffmpegRuns, isEmpty,
        reason: 'building a received video bubble must not run ffmpeg');
    expect(find.byIcon(LucideIcons.play), findsOneWidget,
        reason: 'the bytes are here, so the bubble still offers play');

    // Rebuilds, as a scrolling chat does, change nothing.
    await tester.pump(const Duration(seconds: 1));
    expect(ffmpegRuns, isEmpty);

    // The tap is the user opening the video: from here a poster may be cut.
    await tester.tap(find.byIcon(LucideIcons.play));
    await tester.pump();
    await tester.pump();
    expect(ffmpegRuns, hasLength(1));

    await drain(tester);
  });

  testWidgets('our_own_video_keeps_its_local_poster', (tester) async {
    await pumpBubble(tester, video(videoOnDisk('sent')), isMine: true);

    expect(ffmpegRuns, hasLength(1),
        reason: 'a video we sent is our own file, so its poster is cut');

    await drain(tester);
  });

  testWidgets('a_received_album_tile_is_not_decoded_before_it_opens',
      (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: VideoMessageBubble(
                attachment: video(videoOnDisk('tile')),
                tileSize: const Size(120, 120),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(ffmpegRuns, isEmpty);

    await drain(tester);
  });
}

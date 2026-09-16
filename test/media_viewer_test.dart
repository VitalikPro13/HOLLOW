/// The media viewer route: what it shows, what it lets you do, and what it
/// refuses to offer when the host gave it nothing to act on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/media/media_item.dart';
import 'package:hollow/src/ui/media/media_playback_session.dart';
import 'package:hollow/src/ui/media/media_strip.dart';
import 'package:hollow/src/ui/media/media_viewer_controls.dart';
import 'package:hollow/src/ui/media/media_viewer_route.dart';
import 'package:hollow/src/ui/media/media_viewer_scope.dart';

/// 1x1 transparent PNG; what the mocked at-rest read hands the decoder.
final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hollow_media_viewer');
    AtRest.debugRead = (_) async => _png;
    mediaViewerCrispPixels = true;
    ReduceMotionController.instance.setMode(ReduceMotionMode.off);
  });

  tearDown(() {
    AtRest.debugRead = null;
    MediaLibrary.debugLoader = null;
    ReduceMotionController.instance.setMode(ReduceMotionMode.auto);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// A file whose CONTENT is irrelevant: on disk it is ciphertext, and the
  /// mocked read is what hands the widget pixels.
  MediaItem itemNamed(String name, int ts) {
    final path = '${tmp.path}${Platform.pathSeparator}$name.png';
    File(path).writeAsBytesSync(<int>[0x48, 0x46, 0x45, 0x31]);
    return MediaItem(
      attachment: FileAttachment(
        fileId: name,
        fileName: '$name.png',
        fileExt: 'png',
        mimeType: 'image/png',
        sizeBytes: 1024,
        isImage: true,
        width: 100,
        height: 100,
        totalChunks: 1,
        isComplete: true,
        diskPath: path,
      ),
      messageId: 'msg-$name',
      senderId: 'peer-a',
      timestampMs: ts,
      isMine: true,
    );
  }

  /// A video page whose controller the test owns. An uninitialized controller
  /// never reaches the platform, and play and pause still move `isPlaying`.
  (MediaItem, VideoPlayerController) videoItem(String name, int ts) {
    final path = '${tmp.path}${Platform.pathSeparator}$name.mp4';
    File(path).writeAsBytesSync(<int>[0x48, 0x46, 0x45, 0x31]);
    final controller =
        VideoPlayerController.networkUrl(Uri.parse('https://example.invalid'));
    addTearDown(controller.dispose);
    final session = MediaPlaybackSession.debugWrap(controller, path)
      ..attachViewer();
    return (
      MediaItem(
        attachment: FileAttachment(
          fileId: name,
          fileName: '$name.mp4',
          fileExt: 'mp4',
          mimeType: 'video/mp4',
          sizeBytes: 2048,
          isImage: false,
          totalChunks: 1,
          isComplete: true,
          diskPath: path,
        ),
        messageId: 'msg-$name',
        senderId: 'peer-a',
        timestampMs: ts,
        isMine: true,
        session: session,
      ),
      controller,
    );
  }

  /// Pages the viewer's walk: older rows before the opened item, newer after,
  /// both newest first, the way the storage query answers.
  void serveLibrary({
    List<MediaItem> older = const [],
    List<MediaItem> newer = const [],
  }) {
    MediaLibrary.debugLoader = ({
      required String contextType,
      required String contextId,
      int? beforeMs,
      int? afterMs,
      required int limit,
    }) async =>
        beforeMs != null ? older : newer;
  }

  late _FakeFullscreen fullscreen;

  Future<void> open(
    WidgetTester tester,
    MediaItem item, {
    MediaContext? mediaContext,
    MediaViewerActions actions = MediaViewerActions.none,
  }) async {
    fullscreen = _FakeFullscreen();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appShortcutsProvider.overrideWith(() => _FixedShortcuts()),
          fullscreenProvider.overrideWith(() => fullscreen),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Builder(
            builder: (context) => Center(
              child: GestureDetector(
                onTap: () => Navigator.of(context).push(mediaViewerRoute(
                  item: item,
                  mediaContext: mediaContext,
                  actions: actions,
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Lets the control-fade timer fire, so no timer outlives the test.
  Future<void> drainChrome(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  Finder byLabel(String label) => find.byWidgetPredicate(
      (w) => w is HollowPressable && w.semanticLabel == label);

  bool windowIsFullscreen(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
          .read(fullscreenProvider);

  testWidgets('the counter says where you are and the arrows move it',
      (tester) async {
    final opened = itemNamed('a', 1000);
    serveLibrary(
      older: [opened],
      newer: [itemNamed('c', 3000), itemNamed('b', 2000)],
    );

    await open(tester, opened,
        mediaContext:
            const MediaContext(contextType: 'dm', contextId: 'peer-a'));

    expect(find.text('1 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 of 3'), findsOneWidget);
    await drainChrome(tester);
  });

  testWidgets('escape closes the viewer', (tester) async {
    final opened = itemNamed('a', 1000);
    await open(tester, opened);
    expect(find.byType(MediaViewerView), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerView), findsNothing);
  });

  testWidgets('with no host there is nothing to reply to, react to or save',
      (tester) async {
    await open(tester, itemNamed('a', 1000));

    expect(byLabel('Reply'), findsNothing);
    expect(byLabel('React'), findsNothing);
    expect(byLabel('Save as'), findsNothing);
    expect(byLabel('Delete'), findsNothing);
    expect(byLabel('Close'), findsOneWidget);
    await drainChrome(tester);
  });

  testWidgets('delete asks first, then moves to what is left', (tester) async {
    final opened = itemNamed('a', 1000);
    final deleted = <String>[];
    serveLibrary(
      older: [opened],
      newer: [itemNamed('c', 3000), itemNamed('b', 2000)],
    );

    await open(
      tester,
      opened,
      mediaContext: const MediaContext(contextType: 'dm', contextId: 'peer-a'),
      actions: MediaViewerActions(
        onDelete: (messageId) async => deleted.add(messageId),
      ),
    );
    expect(find.text('1 of 3'), findsOneWidget);

    await tester.tap(byLabel('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this message?'), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byType(HollowDialog), matching: find.text('Delete')));
    await tester.pumpAndSettle();

    expect(deleted, ['msg-a']);
    expect(find.text('1 of 2'), findsOneWidget);
    await drainChrome(tester);
  });

  testWidgets('reduce motion keeps the controls up', (tester) async {
    ReduceMotionController.instance.setMode(ReduceMotionMode.on);
    await open(tester, itemNamed('a', 1000));

    await tester.pump(const Duration(seconds: 3));
    final fade = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity).first);
    expect(fade.opacity, 1.0);
  });

  testWidgets('crisp pixels turn interpolation off past twice actual size',
      (tester) async {
    await open(
      tester,
      itemNamed('a', 1000),
      actions: MediaViewerActions(onSaveAs: (_) async {}),
    );

    // 100 image pixels shown 100 logical pixels wide at dpr 1: fit IS actual
    // size, so four zoom steps of 1.25 clear the 2x mark.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pumpAndSettle();
    }
    expect(tester.widget<Image>(find.byType(Image)).filterQuality,
        FilterQuality.none);

    await tester.tap(byLabel('Crisp pixels'));
    await tester.pumpAndSettle();
    expect(tester.widget<Image>(find.byType(Image)).filterQuality,
        FilterQuality.high);
    await drainChrome(tester);
  });
  testWidgets('the video transport sits above the strip and takes taps',
      (tester) async {
    final (video, controller) = videoItem('v', 1000);
    await controller.play();
    expect(controller.value.isPlaying, isTrue);
    serveLibrary(older: [video], newer: [itemNamed('b', 2000)]);

    await open(tester, video,
        mediaContext:
            const MediaContext(contextType: 'dm', contextId: 'peer-a'));

    expect(find.byType(MediaVideoControls), findsOneWidget);
    expect(find.byType(MediaStrip), findsOneWidget);
    // Bottom chrome, in order: the transport, then the strip under it.
    expect(
      tester.getRect(find.byType(MediaVideoControls)).bottom,
      lessThanOrEqualTo(tester.getRect(find.byType(MediaStrip)).top),
    );

    await tester.tap(byLabel('Pause video'));
    await tester.pump();
    expect(controller.value.isPlaying, isFalse);
    await drainChrome(tester);
  });
  testWidgets('a fullscreen entered while walking is left by Escape, the '
      'viewer by the next one', (tester) async {
    final image = itemNamed('a', 1000);
    final (video, _) = videoItem('v', 2000);
    serveLibrary(older: [image], newer: [video]);

    await open(tester, image,
        mediaContext:
            const MediaContext(contextType: 'dm', contextId: 'peer-a'));
    expect(find.text('1 of 2'), findsOneWidget);

    // Walk to the video; its transport carries the fullscreen control.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);

    await tester.tap(byLabel('Enter fullscreen'));
    await tester.pumpAndSettle();
    expect(windowIsFullscreen(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(windowIsFullscreen(tester), isFalse);
    expect(find.byType(MediaViewerView), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerView), findsNothing);
  });

  testWidgets('a viewer opened from a video bubble leaves both at once',
      (tester) async {
    final (video, _) = videoItem('v', 1000);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appShortcutsProvider.overrideWith(() => _FixedShortcuts()),
          fullscreenProvider.overrideWith(() => fullscreen = _FakeFullscreen()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Builder(
            builder: (context) => Center(
              child: GestureDetector(
                onTap: () => Navigator.of(context).push(mediaViewerRoute(
                  item: video,
                  enterFullscreen: true,
                )),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(windowIsFullscreen(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(MediaViewerView), findsNothing);
    // The exit is queued from dispose, which lands after the pop settles.
    await tester.pump(const Duration(milliseconds: 50));
    expect(windowIsFullscreen(tester), isFalse);
  });
}

/// The window fullscreen without the runner channel a widget test has no host
/// for.
///
/// Both moves hop a microtask like the real notifier's queue does, because
/// they are called from `initState` and `dispose`, where Riverpod refuses a
/// synchronous write.
class _FakeFullscreen extends FullscreenNotifier {
  @override
  bool build() => false;

  @override
  Future<bool> enter() async {
    await Future<void>.delayed(Duration.zero);
    state = true;
    return true;
  }

  @override
  Future<void> exit() async {
    await Future<void>.delayed(Duration.zero);
    state = false;
  }

  @override
  Future<void> toggle() async {
    if (state) {
      await exit();
    } else {
      await enter();
    }
  }
}

/// The shortcut map without the storage round trip the real notifier makes.
class _FixedShortcuts extends AppShortcutsNotifier {
  @override
  Future<Map<AppShortcut, HotkeyBinding>> build() async => kAppShortcutDefaults;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Part B of the media viewer plan: one viewer route for images, GIFs and
/// video. The two surfaces it replaced are gone, and the rules the viewer must
/// not drift back across are source scans, because each of them fails silently
/// at runtime: a raw `localToGlobal` lands a popup half a screen away under
/// interface zoom, an `Opacity` widget costs a saveLayer per item, a repeating
/// animation requests a frame every vsync, and a `dart:io` read of a data-root
/// file returns ciphertext.
void main() {
  Iterable<File> dartFilesUnder(String path) sync* {
    final dir = Directory(path);
    expect(dir.existsSync(), isTrue,
        reason: 'expected to run from the project root ($path missing)');
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.dart')) yield entity;
    }
  }

  /// Every `file:line` under [root] matching [pattern], skipping files whose
  /// name is in [allow].
  List<String> hits(
    String root,
    Pattern pattern, {
    Set<String> allow = const {},
  }) {
    final found = <String>[];
    for (final file in dartFilesUnder(root)) {
      final name = file.path.split(Platform.pathSeparator).last;
      if (allow.contains(name)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains(pattern)) found.add('${file.path}:${i + 1}');
      }
    }
    return found;
  }

  void expectAbsent(String root, Pattern pattern, String why,
      {Set<String> allow = const {}}) {
    final offenders = hits(root, pattern, allow: allow);
    expect(offenders, isEmpty, reason: '\n$why\n  ${offenders.join('\n  ')}\n');
  }

  test('the two surfaces the viewer replaced are gone', () {
    expectAbsent('lib', '_FullscreenImageView',
        'The image dialog is replaced by the media viewer route:');
    expectAbsent('lib', 'FullscreenVideoView',
        'The video view is absorbed into the media viewer route:');
    expectAbsent('lib', 'fullscreenVideoRoute',
        'Video fullscreen pushes mediaViewerRoute now:');
  });

  test('the viewer anchors through overlay space, never window space', () {
    expectAbsent(
      'lib/src/ui/media',
      'localToGlobal(',
      'Interface zoom puts a transform between the window and the Navigator, '
          'so anchors go through overlayAnchorOf / overlayPositionOf:',
    );
  });

  test('the viewer body is a route, not a dialog', () {
    expectAbsent(
      'lib/src/ui/media',
      'showHollowDialog(',
      'A dialog has a blur barrier and an inset box, which is the opposite of '
          'a viewer. Only the delete confirmation may open one:',
      allow: const {'media_viewer_route.dart'},
    );
  });

  test('no repeating animation in the viewer', () {
    expectAbsent(
      'lib/src/ui/media',
      '.repeat(',
      'A running Ticker requests a frame every vsync even when nothing '
          'changed; decorative motion is a Timer:',
    );
  });

  test('per-item opacity is animated, never the Opacity widget', () {
    expectAbsent(
      'lib/src/ui/media',
      RegExp(r'(?<![A-Za-z_])Opacity\('),
      'Opacity costs a saveLayer per paint; AnimatedOpacity composites on the '
          'GPU:',
    );
  });

  test('no dart:io read of an attachment', () {
    for (final needle in const ['readAsBytes', 'openRead(', 'readAsString']) {
      expectAbsent(
        'lib/src/ui/media',
        needle,
        'Content files are encrypted at rest; reads go through AtRest:',
      );
    }
  });
}

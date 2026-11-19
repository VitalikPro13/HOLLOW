import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';

/// Source scan of the platform-decoder halves of [VideoThumbnailService]:
/// every phone and the Mac answer the same channel with the same methods,
/// and the two Swift copies stay one file.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

const _swift = 'ios/Runner/VideoPoster.swift';
const _kotlin =
    'android/app/src/main/kotlin/com/anonlisten/hollow/VideoPoster.kt';

void main() {
  const name = VideoThumbnailService.nativeChannelName;

  test('the iOS and macOS Swift copies are identical', () {
    expect(_read(_swift), _read('macos/Runner/VideoPoster.swift'));
  });

  test('both Xcode projects compile the Swift file', () {
    for (final p in ['ios', 'macos']) {
      expect(
        _read('$p/Runner.xcodeproj/project.pbxproj'),
        contains('/* VideoPoster.swift in Sources */,'),
        reason: p,
      );
    }
  });

  test('every platform decoder names the channel and its two methods', () {
    for (final src in [_swift, _kotlin]) {
      final code = _read(src);
      expect(code, contains('"$name"'), reason: src);
      for (final method in ['"sample"', '"frame"']) {
        expect(code, contains(method), reason: '$src $method');
      }
      for (final arg in [
        '"path"',
        '"timesMs"',
        '"atMs"',
        '"maxHeight"',
        '"deadlineMs"',
      ]) {
        expect(code, contains(arg), reason: '$src $arg');
      }
      for (final key in ['"durationMs"', '"width"', '"height"', '"lumas"']) {
        expect(code, contains(key), reason: '$src $key');
      }
    }
  });

  test('every frame answer carries its image under "image"', () {
    for (final src in [
      _kotlin,
      'ios/Runner/AppDelegate.swift',
      'macos/Runner/MainFlutterWindow.swift',
    ]) {
      expect(_read(src), contains('["image"]'), reason: src);
    }
  });

  test('the Apple decoder never follows a reference movie', () {
    expect(_read(_swift), contains('AVAssetReferenceRestrictions.forbidAll'));
    expect(_read(_swift), contains('cancelAllCGImageGeneration'));
  });

  test('every runner registers the decoder', () {
    expect(
      _read('ios/Runner/AppDelegate.swift'),
      contains('name: VideoPoster.channelName'),
    );
    expect(
      _read('macos/Runner/MainFlutterWindow.swift'),
      contains('name: VideoPoster.channelName'),
    );
    expect(
      _read(
        'android/app/src/main/kotlin/com/anonlisten/hollow/MainActivity.kt',
      ),
      contains(
        'VideoPoster.register(flutterEngine.dartExecutor.binaryMessenger)',
      ),
    );
  });
}

/// The call notification's face (#154): drawn by us as raw pixels, a still
/// for an animated avatar, centre-cropped, nothing for bytes that do not decode.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/os_call_avatar.dart';
import 'package:image/image.dart' as img;

/// RGBA at (x, y) of a rendered face.
List<int> _px(OsCallAvatar a, int x, int y) {
  final i = (y * a.side + x) * 4;
  return a.rgba.sublist(i, i + 4);
}

void _near(List<int> got, List<int> want) {
  for (var i = 0; i < 4; i++) {
    expect((got[i] - want[i]).abs(), lessThanOrEqualTo(8),
        reason: 'channel $i of $got vs $want');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a still is drawn into a square of raw RGBA pixels', () async {
    final png = img.encodePng(img.Image(width: 4, height: 4)
      ..clear(img.ColorRgba8(200, 20, 20, 255)));
    final a = await renderOsCallAvatar(png, side: 8);
    expect(a, isNotNull);
    expect(a!.side, 8);
    expect(a.rgba.length, 8 * 8 * 4);
    _near(_px(a, 4, 4), [200, 20, 20, 255]);
  });

  test('a wide image keeps its centre, never squashed', () async {
    // Left third blue, middle third green, right third blue.
    final wide = img.Image(width: 60, height: 20)
      ..clear(img.ColorRgba8(0, 0, 255, 255));
    img.fillRect(wide,
        x1: 20, y1: 0, x2: 39, y2: 19, color: img.ColorRgba8(0, 255, 0, 255));
    final a = await renderOsCallAvatar(img.encodePng(wide), side: 8);
    _near(_px(a!, 1, 4), [0, 255, 0, 255]);
    _near(_px(a, 6, 4), [0, 255, 0, 255]);
  });

  test('an animated avatar gives its first frame', () async {
    final first = img.Image(width: 4, height: 4)
      ..clear(img.ColorRgb8(255, 0, 0));
    final second = img.Image(width: 4, height: 4)
      ..clear(img.ColorRgb8(0, 0, 255));
    first.addFrame(second);
    final gif = img.encodeGif(first);
    final a = await renderOsCallAvatar(gif, side: 4);
    expect(a, isNotNull);
    final p = _px(a!, 2, 2);
    expect(p[0], greaterThan(200), reason: 'red, the first frame: $p');
    expect(p[2], lessThan(50));
  });

  test('bytes that do not decode give no face', () async {
    expect(await renderOsCallAvatar(Uint8List.fromList([1, 2, 3, 4])), isNull);
    expect(await renderOsCallAvatar(Uint8List(0)), isNull);
  });

  test('the default side fits what native accepts', () {
    // OsCallRules.AVATAR_MAX_SIDE on Android.
    expect(kOsCallAvatarSide, inInclusiveRange(1, 256));
  });
}

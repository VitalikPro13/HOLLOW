import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/core/services/gif_thumb_cache.dart';

/// GifThumbCache shipped the same self-referential `whenComplete` as
/// GifCatalog: `whenComplete(() => _inflight.remove(url))` returns the removed
/// Future — the very future being completed — so `load()` never resolved for
/// its caller and grid cells stayed blank, even though `_load` had already
/// filled the RAM tier (which is why reopening the picker painted them).
///
/// The guard is simply "the returned future settles". Plain `test()`, never
/// `testWidgets()`: under FakeAsync a permanent hang is indistinguishable from
/// waiting. Hermetic — HttpOverrides denies the network, so a failed load is
/// the expected outcome and `null` is the correct answer.

Future<T> _bounded<T>(Future<T> f) =>
    f.timeout(const Duration(seconds: 5), onTimeout: () {
      fail('load() never completed for its caller (whenComplete self-wait?)');
    });

Future<Uint8List> _offline(String _) async =>
    throw const SocketException('network denied in tests');

void main() {
  test('load(): the caller\'s future settles even when the fetch fails',
      () async {
    GifThumbCache.debugFetch = _offline;
    final bytes = await _bounded(
        GifThumbCache.instance.load('https://proxy.test/gifs/m/a.still.webp'));
    expect(bytes, isNull);
  });

  test('load(): every caller sharing one in-flight url settles', () async {
    GifThumbCache.debugFetch = _offline;
    const url = 'https://proxy.test/gifs/m/b.still.webp';
    final a = GifThumbCache.instance.load(url);
    final b = GifThumbCache.instance.load(url);
    expect(await _bounded(a), isNull);
    expect(await _bounded(b), isNull);
    // Slot freed, so a later cell can retry the same url.
    expect(await _bounded(GifThumbCache.instance.load(url)), isNull);
  });

  test('a preview the image check is still on is asked again, a refused one '
      'never paints', () async {
    AtRest.debugImageRetryDelay = Duration.zero;
    var asks = 0;
    GifThumbCache.debugFetch = (_) async {
      if (++asks < 3) throw Exception(kImageNotYet);
      return Uint8List.fromList([1, 2, 3]);
    };
    expect(await _bounded(
        GifThumbCache.instance.load('https://proxy.test/gifs/m/c.webp')), [1, 2, 3]);
    expect(asks, 3);
    GifThumbCache.debugFetch =
        (_) async => throw Exception("Hollow can't show this image");
    expect(await _bounded(
        GifThumbCache.instance.load('https://proxy.test/gifs/m/d.webp')), isNull);
    AtRest.debugImageRetryDelay = const Duration(seconds: 1);
  });
  test('a preview the image check is still on frees its download slot while '
      'it waits', () async {
    AtRest.debugImageRetryDelay = const Duration(milliseconds: 300);
    final asked = <String>{};
    GifThumbCache.debugFetch = (url) async {
      if (url.contains('slow') && asked.add(url)) throw Exception(kImageNotYet);
      return Uint8List.fromList([7]);
    };
    final slow = [
      for (var i = 0; i < 4; i++)
        GifThumbCache.instance.load('https://proxy.test/gifs/m/slow$i.webp'),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final clock = Stopwatch()..start();
    expect(
        await _bounded(
            GifThumbCache.instance.load('https://proxy.test/gifs/m/fast.webp')),
        [7]);
    expect(clock.elapsedMilliseconds, lessThan(200),
        reason: 'a preview waiting on the check held a download slot');
    for (final s in slow) {
      expect(await _bounded(s), [7]);
    }
    AtRest.debugImageRetryDelay = const Duration(seconds: 1);
  });
}

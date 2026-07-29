import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

Never _offline(SecurityContext? _) =>
    throw const SocketException('network denied in tests');

void main() {
  test('load(): the caller\'s future settles even when the fetch fails',
      () async {
    await HttpOverrides.runZoned(
      () async {
        final bytes = await _bounded(GifThumbCache.instance
            .load('https://proxy.test/gifs/m/a.still.webp'));
        expect(bytes, isNull);
      },
      createHttpClient: _offline,
    );
  });

  test('load(): every caller sharing one in-flight url settles', () async {
    await HttpOverrides.runZoned(
      () async {
        const url = 'https://proxy.test/gifs/m/b.still.webp';
        final a = GifThumbCache.instance.load(url);
        final b = GifThumbCache.instance.load(url);
        expect(await _bounded(a), isNull);
        expect(await _bounded(b), isNull);
        // Slot freed, so a later cell can retry the same url.
        expect(await _bounded(GifThumbCache.instance.load(url)), isNull);
      },
      createHttpClient: _offline,
    );
  });
}

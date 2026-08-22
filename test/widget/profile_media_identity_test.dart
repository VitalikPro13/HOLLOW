/// Reloading unchanged profile media must keep the SAME byte-list instance.
///
/// [AnimatedGifImage] cannot afford to compare megabytes on every rebuild, so
/// it re-decodes on `!identical(old.bytes, widget.bytes)`. `ProfileUpdated`
/// invalidates the avatar and banner caches on EVERY profile save, whether or
/// not either was touched — so a provider that returns a fresh-but-equal list
/// makes every animated surface throw its decoded frames away and start over.
///
/// That is what made a profile save look like it wiped the banner: a 1.1 MB
/// animated GIF took long enough to re-decode that the settings preview sat on
/// its gradient placeholder. Nothing was lost; it was re-decoding the same
/// bytes it already had.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';

void main() {
  test('equal bytes keep their identity, different bytes do not', () {
    final cache = <String, Uint8List>{};
    final first = Uint8List.fromList([1, 2, 3, 4]);

    expect(identical(reuseIfUnchanged(cache, 'p', first), first), isTrue,
        reason: 'the first load is handed straight through');

    // A reload: same content, brand-new list, as an FFI round trip produces.
    final reload = Uint8List.fromList([1, 2, 3, 4]);
    expect(identical(reuseIfUnchanged(cache, 'p', reload), first), isTrue,
        reason: 'unchanged bytes must keep the instance the widgets hold');

    final changed = Uint8List.fromList([1, 2, 3, 5]);
    expect(identical(reuseIfUnchanged(cache, 'p', changed), changed), isTrue,
        reason: 'a real change must come through, or the UI would go stale');
    // ...and the new one becomes the baseline.
    expect(
        identical(reuseIfUnchanged(cache, 'p', Uint8List.fromList([1, 2, 3, 5])),
            changed),
        isTrue);
  });

  test('a length change short-circuits before comparing bytes', () {
    final cache = <String, Uint8List>{};
    final short = Uint8List.fromList([9, 9]);
    reuseIfUnchanged(cache, 'p', short);
    final long = Uint8List.fromList([9, 9, 9]);
    expect(identical(reuseIfUnchanged(cache, 'p', long), long), isTrue);
  });

  test('peers do not share a slot', () {
    final cache = <String, Uint8List>{};
    final a = Uint8List.fromList([1, 1]);
    final b = Uint8List.fromList([1, 1]);
    reuseIfUnchanged(cache, 'a', a);
    expect(identical(reuseIfUnchanged(cache, 'b', b), b), isTrue,
        reason: 'two peers with identical bytes must not alias each other');
  });
}

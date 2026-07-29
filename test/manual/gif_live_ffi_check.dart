// MANUAL live-network check — run explicitly, never part of the suite
// (no _test.dart suffix on purpose):
//   flutter test test/manual/gif_live_ffi_check.dart
// Loads the REAL Release hollow_core.dll and calls the GIF FFI exactly the
// way the app does, with timing.
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/rust/api/gifs.dart' as gifs_api;
import 'package:hollow/src/rust/frb_generated.dart';

void main() {
  test('live GIF FFI through the Release DLL', () async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
          'build/windows/x64/runner/Release/hollow_core.dll'),
    );

    var t = DateTime.now();
    final trending = await gifs_api.gifTrending(page: 1);
    // ignore: avoid_print
    print('trending: ${trending.items.length} items in '
        '${DateTime.now().difference(t).inMilliseconds}ms');

    t = DateTime.now();
    final search = await gifs_api.gifSearch(query: 'cat', page: 1);
    // ignore: avoid_print
    print('search "cat": ${search.items.length} items in '
        '${DateTime.now().difference(t).inMilliseconds}ms');

    t = DateTime.now();
    final search2 = await gifs_api.gifSearch(query: 'party time', page: 1);
    // ignore: avoid_print
    print('search "party time": ${search2.items.length} items in '
        '${DateTime.now().difference(t).inMilliseconds}ms');

    t = DateTime.now();
    final cats = await gifs_api.gifCategories();
    // ignore: avoid_print
    print('categories: ${cats.length} in '
        '${DateTime.now().difference(t).inMilliseconds}ms');

    expect(trending.items, isNotEmpty);
    expect(search.items, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

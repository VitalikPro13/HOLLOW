import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';

class _ManifestApi implements RustLibApi {
  bool fail = false;

  @override
  String crateApiUpdaterGetCurrentVersion() => '0.11.1';

  @override
  Future<String> crateApiUpdaterFetchVersionManifest(
      {required String manifestUrl}) async {
    if (fail) throw Exception('offline');
    return '{"latest":"0.11.1","versions":[]}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _ManifestApi();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => api.fail = false);

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  test('a completed check stamps lastChecked', () async {
    final c = container();
    expect(c.read(updaterProvider).lastChecked, isNull);
    final before = DateTime.now();
    await c.read(updaterProvider.notifier).checkForUpdates();
    final stamp = c.read(updaterProvider).lastChecked;
    expect(stamp, isNotNull);
    expect(stamp!.isBefore(before), isFalse);
  });

  test('the background re-check stamps it too', () async {
    final c = container();
    await c.read(updaterProvider.notifier).checkForUpdates(background: true);
    expect(c.read(updaterProvider).lastChecked, isNotNull);
  });

  test('a failed check keeps the last good stamp', () async {
    final c = container();
    await c.read(updaterProvider.notifier).checkForUpdates();
    final good = c.read(updaterProvider).lastChecked;
    api.fail = true;
    await c.read(updaterProvider.notifier).checkForUpdates();
    expect(c.read(updaterProvider).status, UpdateStatus.error);
    expect(c.read(updaterProvider).lastChecked, good);
  });
}

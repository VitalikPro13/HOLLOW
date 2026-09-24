import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// Settings and at-rest files kept in memory; the file itself is written for
/// real so `load()` sees it exist.
class _StoreApi implements RustLibApi {
  final settings = <String, String>{};
  final files = <String, Uint8List>{};

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      settings[key];

  @override
  Future<void> crateApiAtRestWriteAtRest(
      {required String path, required List<int> bytes}) async {
    files[path] = Uint8List.fromList(bytes);
    File(path).writeAsBytesSync(bytes);
  }

  @override
  Future<Uint8List> crateApiAtRestReadAtRest({required String path}) async =>
      files[path]!;

  @override
  Future<void> crateApiAtRestRemoveAtRest({required String path}) async {
    files.remove(path);
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _StoreApi();
  late Directory root;

  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    root = Directory.systemTemp.createTempSync('hollow_bg_');
    overrideHollowDataDir(root.path);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('the picked file name survives a restart', () async {
    final first = ProviderContainer();
    await first
        .read(backgroundProvider.notifier)
        .setImage(Uint8List.fromList([1, 2, 3]), name: 'mountains.png');
    expect(first.read(backgroundProvider).imageName, 'mountains.png');
    first.dispose();

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    await restarted.read(backgroundProvider.notifier).load();
    final state = restarted.read(backgroundProvider);
    expect(state.hasBackground, isTrue);
    expect(state.imageName, 'mountains.png');
  });

  test('removing the image forgets its name', () async {
    final first = ProviderContainer();
    await first
        .read(backgroundProvider.notifier)
        .setImage(Uint8List.fromList([1, 2, 3]), name: 'mountains.png');
    await first.read(backgroundProvider.notifier).clearImage();
    expect(first.read(backgroundProvider).imageName, isNull);
    first.dispose();

    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    await restarted.read(backgroundProvider.notifier).load();
    expect(restarted.read(backgroundProvider).hasBackground, isFalse);
    expect(restarted.read(backgroundProvider).imageName, isNull);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';

class _SettingsApi implements RustLibApi {
  final settings = <String, String>{};

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    settings[key] = value;
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      settings[key];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _SettingsApi();

  setUpAll(() => RustLib.initMock(api: api));
  setUp(api.settings.clear);

  Future<bool> load() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container.read(noiseSuppressAiProvider.future);
  }

  test('noise suppression is on for anyone who never chose', () async {
    expect(await load(), isTrue);
    expect(kNoiseSuppressAiDefault, isTrue);
  });

  test('a user who switched it off keeps it off', () async {
    api.settings['noise_suppress_ai'] = 'false';
    expect(await load(), isFalse);
  });

  test('a user who switched it on keeps it on', () async {
    api.settings['noise_suppress_ai'] = 'true';
    expect(await load(), isTrue);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const _kLicenseKeySettingKey = 'license_key';

class LicenseKeyNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  Future<void> loadCached() async {
    final cached =
        await storage_api.loadSetting(key: _kLicenseKeySettingKey);
    if (cached != null && cached.isNotEmpty) {
      state = cached;
    }
  }

  Future<void> setKey(String key) async {
    state = key;
    await storage_api.saveSetting(
        key: _kLicenseKeySettingKey, value: key);
  }

  Future<void> clearKey() async {
    state = null;
    await storage_api.saveSetting(
        key: _kLicenseKeySettingKey, value: '');
  }
}

final licenseKeyProvider =
    NotifierProvider<LicenseKeyNotifier, String?>(LicenseKeyNotifier.new);

final licenseErrorProvider = StateProvider<String?>((ref) => null);

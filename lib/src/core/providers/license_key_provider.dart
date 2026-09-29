import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Before 0.12 one key served whichever relay was configured.
const _kLegacyLicenseKeySettingKey = 'license_key';

/// A relay's access key is stored under that relay alone, so a relay switch never
/// hands one relay another's key.
String licenseKeySettingKey(String relayDomain) =>
    'license_key:${relayDomain.toLowerCase()}';

/// The access key for the configured relay. Only the user replaces it: a relay's
/// refusal never erases it.
class LicenseKeyNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  String get _settingKey => licenseKeySettingKey(ref.read(relayDomainProvider));

  /// Reads the key of the relay loaded by [RelayDomainNotifier.loadCached], which
  /// must run first.
  Future<void> loadCached() async {
    var cached = await storage_api.loadSetting(key: _settingKey);
    if (cached == null || cached.isEmpty) {
      // The pre-0.12 key was already being sent to the relay configured now.
      final legacy =
          await storage_api.loadSetting(key: _kLegacyLicenseKeySettingKey);
      if (legacy != null && legacy.isNotEmpty) {
        await storage_api.saveSetting(key: _settingKey, value: legacy);
        await storage_api.saveSetting(
            key: _kLegacyLicenseKeySettingKey, value: '');
        cached = legacy;
      }
    }
    state = (cached != null && cached.isNotEmpty) ? cached : null;
  }

  Future<void> setKey(String key) async {
    state = key;
    await storage_api.saveSetting(key: _settingKey, value: key);
  }
}

final licenseKeyProvider =
    NotifierProvider<LicenseKeyNotifier, String?>(LicenseKeyNotifier.new);

final licenseErrorProvider = StateProvider<String?>((ref) => null);

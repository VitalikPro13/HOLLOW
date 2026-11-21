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
    ref.read(relayKeyFullProvider.notifier).state = false;
    await storage_api.saveSetting(key: _settingKey, value: key);
  }
}

final licenseKeyProvider =
    NotifierProvider<LicenseKeyNotifier, String?>(LicenseKeyNotifier.new);

final licenseErrorProvider = StateProvider<String?>((ref) => null);

/// The relay turns our login away because every device seat of our access key
/// is taken (`license_key_in_use`); the node keeps retrying. Cleared once the
/// relay lets us in, or when the person enters another key.
final relayKeyFullProvider = StateProvider<bool>((ref) => false);

/// The connection status while our access key is full.
const String kAccessKeyFullStatus = 'Access key full';

/// The key-full notice's title.
const String kAccessKeyFullTitle = 'Your access key is full';

/// What a full key means and what to do about it.
const String kAccessKeyFullText =
    'This relay lets one access key connect up to five devices at once, and '
    'yours already has five. Ask whoever runs the relay for a key of your own, '
    'or close Hollow on another device that uses it. Hollow keeps trying to '
    'connect.';

/// The toast when the key first turns out full.
const String kAccessKeyFullToast =
    'Your access key is already on five devices. Hollow keeps trying.';

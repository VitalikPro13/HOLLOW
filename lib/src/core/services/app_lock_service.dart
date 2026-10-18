import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:local_auth/local_auth.dart';

/// The shortest PIN Hollow sets; Rust holds new secrets to the same floor. An
/// older, shorter PIN keeps unlocking.
const int kMinPinDigits = 6;

final _onlyDigits = RegExp(r'^\p{N}+$', unicode: true);

/// A secret made only of digits and shorter than [kMinPinDigits].
bool isShortPin(String secret) =>
    _onlyDigits.hasMatch(secret) && secret.length < kMinPinDigits;

/// Where App Lock keeps its entries. The OS secure storage in the app; a map in
/// tests.
abstract class AppLockStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Every entry this app holds, to find the ones a gone profile left.
  Future<Map<String, String>> readAll();
}

/// flutter_secure_storage under the this-device-only class: the items never travel
/// in a backup or to a new phone, so a copied identity file stays useless without
/// this device (C-06).
class SecureAppLockStore implements AppLockStore {
  static const _iOptions =
      IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device);
  static const _mOptions =
      MacOsOptions(accessibility: KeychainAccessibility.unlocked_this_device);

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: _iOptions,
    mOptions: _mOptions,
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  /// Items written before the class changed carry the migrating `unlocked`
  /// class, which the new query no longer matches. Re-saves each under the
  /// this-device class; deleting first is what lets the add through, since the
  /// class is not part of an item's identity.
  Future<void> migrateAccessibility(Iterable<String> keys) async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    const legacyI = IOSOptions();
    const legacyM = MacOsOptions();
    for (final key in keys) {
      String? old;
      try {
        old =
            await _storage.read(key: key, iOptions: legacyI, mOptions: legacyM);
        if (old == null) continue;
        await _storage.delete(key: key);
        await _storage.write(key: key, value: old);
      } catch (e) {
        debugPrint('[HOLLOW-APPLOCK] keychain class migration skipped: $e');
        // A failed re-save must not cost the person their stored secret.
        if (old != null) {
          try {
            await _storage.write(
                key: key, value: old, iOptions: legacyI, mOptions: legacyM);
          } catch (_) {}
        }
      }
    }
  }
}

/// App Lock helper: stores the lock-type marker and, optionally, the secret
/// released by a successful biometric prompt, the launch secret and the
/// longer-PIN flag, each under THIS profile's id, so one profile's entries never
/// open or overwrite another's.
///
/// A PIN is just a numeric secret fed through the same Rust Argon2id + AES-GCM
/// flow that protects the identity; biometric unlock keeps a copy of that
/// secret in the OS-encrypted store and reads it only after `local_auth`
/// succeeds. The entries live in secure storage rather than SQLCipher because
/// they must be readable BEFORE the identity is unlocked, at app launch.
class AppLockService {
  static AppLockService _instance = AppLockService._(
    store: SecureAppLockStore(),
    profileId: _rustProfileId,
    opensIdentity: _rustOpensIdentity,
  );
  factory AppLockService() => _instance;

  AppLockService._({
    required AppLockStore store,
    required String? Function(bool create) profileId,
    required Future<bool> Function(String secret) opensIdentity,
    bool? oneProfile,
  })  : _store = store,
        _profileIdOf = profileId,
        _opensIdentity = opensIdentity,
        _oneProfile = oneProfile ?? (Platform.isAndroid || Platform.isIOS);

  /// A fresh service over fakes, in place of the app's one. [oneProfile]: the
  /// install can hold only one profile, as a phone.
  @visibleForTesting
  static AppLockService debugReplace({
    required AppLockStore store,
    required String? Function(bool create) profileId,
    required Future<bool> Function(String secret) opensIdentity,
    bool oneProfile = false,
  }) =>
      _instance = AppLockService._(
          store: store,
          profileId: profileId,
          opensIdentity: opensIdentity,
          oneProfile: oneProfile);

  static String? _rustProfileId(bool create) =>
      identity_api.appLockProfileId(create: create);

  static Future<bool> _rustOpensIdentity(String secret) =>
      identity_api.appLockSecretOpensIdentity(secret: secret);

  static const _kLockType = 'hollow_app_lock_type'; // 'pin' | 'password'
  static const _kBiometricSecret = 'hollow_app_lock_secret';
  // The unlock secret the OS keystore holds so Hollow can start on its own
  // and the app lock is the only prompt. Absent when the person chose to be
  // asked before Hollow starts.
  static const _kLaunchSecret = 'hollow_app_lock_launch_secret';
  // Set once the person has been asked to trade a short PIN for a longer one.
  static const _kLongerPinAsked = 'hollow_app_lock_longer_pin_asked';
  // This profile has judged the entries from before they were per profile.
  static const _kLegacyChecked = 'hollow_app_lock_legacy_checked';
  // Set once the person was told a duress code from before 0.12.2 can be set
  // again to be tied to this device too.
  static const _kDuressRebindAsked = 'hollow_app_lock_duress_rebind_asked';

  static const _entries = [
    _kLockType,
    _kBiometricSecret,
    _kLaunchSecret,
    _kLongerPinAsked,
  ];

  /// What a profile's clean-up deletes: its entries and its own markers.
  static const _profileEntries = [
    ..._entries,
    _kLegacyChecked,
    _kDuressRebindAsked,
  ];

  /// `<base>.<16 hex>`: an entry some profile's id names.
  static final _scopedEntry =
      RegExp(r'^hollow_app_lock_[a-z_]+\.([0-9a-f]{16})$');
  static const _secrets = {_kBiometricSecret, _kLaunchSecret};

  final AppLockStore _store;
  final String? Function(bool create) _profileIdOf;
  final Future<bool> Function(String secret) _opensIdentity;
  final bool _oneProfile;

  /// Held once known: a wipe deletes the id file, and its clean-up still has to
  /// find the entries the id named.
  String? _id;

  String? _profileId({bool create = false}) {
    if (_id != null) return _id;
    try {
      return _id = _profileIdOf(create);
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] no profile id: $e');
      return null;
    }
  }

  static String _scoped(String base, String id) => '$base.$id';

  Future<void>? _legacy;

  Future<void> _ready() => _legacy ??= _settleLegacy();

  /// Entries from before 0.12.2 are global. They move ONCE into the profile they
  /// belong to: the one whose identity a stored secret actually opens. On a
  /// desktop a profile they do not open leaves them for another, and none is ever
  /// unlocked by another's secret. A phone has one profile: its markers move, a
  /// secret moves only if it opens the identity, and the rest is stale.
  Future<void> _settleLegacy() async {
    final store = _store;
    if (store is SecureAppLockStore) {
      await store.migrateAccessibility(_entries);
    }
    final legacy = <String, String>{};
    for (final base in _entries) {
      try {
        final v = await store.read(base);
        if (v != null && v.isNotEmpty) legacy[base] = v;
      } catch (_) {}
    }
    if (legacy.isEmpty) return;
    final known = _profileId();
    if (known != null &&
        await _readRaw(_scoped(_kLegacyChecked, known)) != null) {
      return;
    }
    final adopt = <String, String>{};
    var proven = false;
    try {
      for (final entry in legacy.entries) {
        if (!_secrets.contains(entry.key)) continue;
        if (await _opensIdentity(entry.value)) {
          adopt[entry.key] = entry.value;
          proven = true;
        }
      }
    } catch (e) {
      // No identity to judge against yet: the next launch with one decides.
      debugPrint('[HOLLOW-APPLOCK] legacy entries wait: $e');
      return;
    }
    final id = _profileId(create: true);
    if (id == null) return;
    if (proven || _oneProfile) {
      for (final entry in legacy.entries) {
        if (!_secrets.contains(entry.key)) adopt[entry.key] = entry.value;
      }
      for (final entry in adopt.entries) {
        final key = _scoped(entry.key, id);
        if (await _readRaw(key) == null) await store.write(key, entry.value);
      }
      for (final base in legacy.keys) {
        try {
          await store.delete(base);
        } catch (_) {}
      }
    }
    await store.write(_scoped(_kLegacyChecked, id), '1');
  }

  Future<String?> _readRaw(String key) async {
    try {
      return await _store.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _read(String base) async {
    await _ready();
    final id = _profileId();
    if (id == null) return null;
    return _store.read(_scoped(base, id));
  }

  Future<void> _write(String base, String value) async {
    await _ready();
    final id = _profileId(create: true);
    if (id == null) throw StateError('no profile to store App Lock entries in');
    await _store.write(_scoped(base, id), value);
  }

  Future<void> _delete(String base) async {
    await _ready();
    final id = _profileId();
    if (id == null) return;
    await _store.delete(_scoped(base, id));
  }

  late final _localAuth = LocalAuthentication();

  /// The secret the user typed when enabling/unlocking App Lock this session.
  /// Lets the biometric toggle store it without re-prompting.
  String? sessionSecret;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// 'pin', 'password', or null when no marker is stored (defaults to
  /// password-style entry for locks created before this marker existed).
  Future<String?> getLockType() async {
    try {
      return await _read(_kLockType);
    } catch (_) {
      return null;
    }
  }

  Future<void> setLockType(String? type) async {
    try {
      if (type == null) {
        await _delete(_kLockType);
      } else {
        await _write(_kLockType, type);
      }
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] setLockType failed: $e');
    }
  }

  /// Whether this device can show a fingerprint/Face ID prompt at all.
  Future<bool> canUseBiometrics() async {
    if (!_isMobile) return false;
    try {
      if (!await _localAuth.isDeviceSupported()) return false;
      final available = await _localAuth.getAvailableBiometrics();
      return available.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether a biometric-released secret is stored.
  Future<bool> isBiometricEnabled() async {
    try {
      final v = await _read(_kBiometricSecret);
      return v != null && v.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> enableBiometric(String secret) async {
    await _write(_kBiometricSecret, secret);
  }

  Future<void> disableBiometric() async {
    try {
      await _delete(_kBiometricSecret);
    } catch (_) {}
  }

  Future<String?> readLaunchSecret() async {
    try {
      final v = await _read(_kLaunchSecret);
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasLaunchSecret() async => (await readLaunchSecret()) != null;

  Future<void> storeLaunchSecret(String secret) async {
    try {
      await _write(_kLaunchSecret, secret);
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] storeLaunchSecret failed: $e');
    }
  }

  Future<void> clearLaunchSecret() async {
    try {
      await _delete(_kLaunchSecret);
    } catch (_) {}
  }

  Future<bool> longerPinAsked() async {
    try {
      return await _read(_kLongerPinAsked) != null;
    } catch (_) {
      // Unreadable: better never to ask than to ask at every unlock.
      return true;
    }
  }

  Future<void> markLongerPinAsked() async {
    try {
      await _write(_kLongerPinAsked, '1');
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] markLongerPinAsked failed: $e');
    }
  }

  /// Whether the one-time note about setting an old duress code again was shown.
  Future<bool> duressRebindAsked() async {
    try {
      return await _read(_kDuressRebindAsked) != null;
    } catch (_) {
      return true;
    }
  }

  Future<void> markDuressRebindAsked() async {
    try {
      await _write(_kDuressRebindAsked, '1');
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] markDuressRebindAsked failed: $e');
    }
  }

  /// Clear this profile's entries (App Lock removed, or the profile wiped).
  /// Another profile's stay. A phone holds one profile, so there every entry
  /// another id names is a gone profile's: a wipe finished by another process
  /// (the push fetch, a boot wipe) deleted the id file before anything here
  /// could read it, and its PIN must not outlive it in secure storage.
  Future<void> clearAll() async {
    sessionSecret = null;
    final id = _profileId();
    if (id != null) await clearProfile(id);
    if (_oneProfile) await _clearOtherProfiles(id);
  }

  Future<void> _clearOtherProfiles(String? live) async {
    final Map<String, String> all;
    try {
      all = await _store.readAll();
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] no entry list: $e');
      return;
    }
    for (final key in all.keys) {
      final m = _scopedEntry.firstMatch(key);
      if (m == null || m.group(1) == live) continue;
      try {
        await _store.delete(key);
      } catch (_) {}
    }
  }

  /// Clear the entries of the profile named [id], such as one about to be erased
  /// from the profile list.
  Future<void> clearProfile(String id) async {
    for (final base in _profileEntries) {
      try {
        await _store.delete(_scoped(base, id));
      } catch (_) {}
    }
  }

  /// Shows the OS biometric prompt with no secret involved, to verify the
  /// sensor works before trusting it for unlocks.
  Future<bool> promptBiometric(
      {String reason = 'Confirm fingerprint / Face ID'}) async {
    if (!_isMobile) return false;
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] biometric prompt failed: $e');
      return false;
    }
  }

  /// Show the OS biometric prompt; on success return the stored secret.
  /// Returns null if unavailable, cancelled, or failed.
  Future<String?> authenticateAndGetSecret() async {
    if (!_isMobile) return null;
    try {
      if (!await isBiometricEnabled()) return null;
      if (!await promptBiometric(reason: 'Unlock Hollow')) return null;
      return await _read(_kBiometricSecret);
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] biometric auth failed: $e');
      return null;
    }
  }
}

/// Seconds Rust still makes the next typed secret wait, from its
/// `too_many_attempts: <seconds>` answer; null for any other error.
int? appLockWaitFrom(Object error) {
  final m = RegExp(r'too_many_attempts:\s*(\d+)').firstMatch(error.toString());
  return m == null ? null : int.tryParse(m.group(1)!);
}

/// What the field says while too many misses make the next try wait.
String appLockWaitText(int seconds) {
  final String when;
  if (seconds >= 120) {
    when = '${(seconds / 60).ceil()} minutes';
  } else if (seconds > 60) {
    when = '2 minutes';
  } else if (seconds == 60) {
    when = '1 minute';
  } else {
    when = seconds == 1 ? '1 second' : '$seconds seconds';
  }
  return 'Too many tries. You can try again in $when.';
}

/// True when Rust says the device-bound wrap's hardware key is gone. Nothing was
/// deleted; the recovery phrase is the way back.
bool isHardwareKeyMissing(Object error) =>
    error.toString().contains('hardware_key_missing');

/// True when the phone's secure hardware did not answer this once. The key is
/// still there and the try was not counted: the same try may simply be made again.
bool isHardwareKeyBusy(Object error) =>
    error.toString().contains('hardware_key_busy');

/// True only when the secret itself was wrong: a stored copy that fails this way
/// is stale (changed through recovery). A busy keystore, a wait or a missing key
/// says nothing about the secret.
bool isWrongSecret(Object error) =>
    error.toString().contains('Wrong password');

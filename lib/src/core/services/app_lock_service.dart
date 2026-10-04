import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

/// The shortest PIN Hollow sets; Rust holds new secrets to the same floor. An
/// older, shorter PIN keeps unlocking.
const int kMinPinDigits = 6;

final _onlyDigits = RegExp(r'^\p{N}+$', unicode: true);

/// A secret made only of digits and shorter than [kMinPinDigits].
bool isShortPin(String secret) =>
    _onlyDigits.hasMatch(secret) && secret.length < kMinPinDigits;

/// App Lock helper: stores the lock-type marker and, optionally, the secret
/// released by a successful biometric prompt.
///
/// A PIN is just a numeric secret fed through the same Rust Argon2id + AES-GCM
/// flow that protects the identity; biometric unlock keeps a copy of that
/// secret in the OS-encrypted store and reads it only after `local_auth`
/// succeeds. The lock-type marker lives in secure storage rather than
/// SQLCipher because it must be readable BEFORE the identity is unlocked, at
/// app launch.
class AppLockService {
  static final AppLockService _instance = AppLockService._();
  factory AppLockService() => _instance;
  AppLockService._();

  static const _kLockType = 'hollow_app_lock_type'; // 'pin' | 'password'
  static const _kBiometricSecret = 'hollow_app_lock_secret';
  // The unlock secret the OS keystore holds so Hollow can start on its own
  // and the app lock is the only prompt. Absent when the person chose to be
  // asked before Hollow starts.
  static const _kLaunchSecret = 'hollow_app_lock_launch_secret';
  // Set once the person has been asked to trade a short PIN for a longer one.
  static const _kLongerPinAsked = 'hollow_app_lock_longer_pin_asked';

  // This-device-only: the items never travel in a backup or to a new phone,
  // so a copied identity file stays useless without this device (C-06).
  static const _iOptions =
      IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device);
  static const _mOptions =
      MacOsOptions(accessibility: KeychainAccessibility.unlocked_this_device);

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: _iOptions,
    mOptions: _mOptions,
  );
  final _localAuth = LocalAuthentication();

  /// Items written before the class changed carry the migrating
  /// `unlocked` class, which the new query no longer matches.
  Future<void>? _migration;

  Future<void> _migrated() => _migration ??= _migrateAccessibility();

  /// Re-saves every item under the this-device class. Deleting first is what
  /// lets the add through: the accessibility class is not part of an item's
  /// identity, so the old one would block it.
  Future<void> _migrateAccessibility() async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }
    const legacyI = IOSOptions();
    const legacyM = MacOsOptions();
    for (final key in [
      _kLockType,
      _kBiometricSecret,
      _kLaunchSecret,
      _kLongerPinAsked,
    ]) {
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

  Future<String?> _read(String key) async {
    await _migrated();
    return _storage.read(key: key);
  }

  Future<void> _write(String key, String value) async {
    await _migrated();
    await _storage.write(key: key, value: value);
  }

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
        await _storage.delete(key: _kLockType);
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
      await _storage.delete(key: _kBiometricSecret);
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
      await _storage.delete(key: _kLaunchSecret);
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

  /// Clear everything (called when App Lock is removed).
  Future<void> clearAll() async {
    sessionSecret = null;
    await setLockType(null);
    await disableBiometric();
    await clearLaunchSecret();
    try {
      await _storage.delete(key: _kLongerPinAsked);
    } catch (_) {}
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

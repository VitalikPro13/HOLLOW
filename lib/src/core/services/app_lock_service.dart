import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

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

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );
  final _localAuth = LocalAuthentication();

  /// The secret the user typed when enabling/unlocking App Lock this session.
  /// Lets the biometric toggle store it without re-prompting.
  String? sessionSecret;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// 'pin', 'password', or null when no marker is stored (defaults to
  /// password-style entry for locks created before this marker existed).
  Future<String?> getLockType() async {
    try {
      return await _storage.read(key: _kLockType);
    } catch (_) {
      return null;
    }
  }

  Future<void> setLockType(String? type) async {
    try {
      if (type == null) {
        await _storage.delete(key: _kLockType);
      } else {
        await _storage.write(key: _kLockType, value: type);
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
      final v = await _storage.read(key: _kBiometricSecret);
      return v != null && v.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> enableBiometric(String secret) async {
    await _storage.write(key: _kBiometricSecret, value: secret);
  }

  Future<void> disableBiometric() async {
    try {
      await _storage.delete(key: _kBiometricSecret);
    } catch (_) {}
  }

  /// Clear everything (called when App Lock is removed).
  Future<void> clearAll() async {
    sessionSecret = null;
    await setLockType(null);
    await disableBiometric();
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
      return await _storage.read(key: _kBiometricSecret);
    } catch (e) {
      debugPrint('[HOLLOW-APPLOCK] biometric auth failed: $e');
      return null;
    }
  }
}

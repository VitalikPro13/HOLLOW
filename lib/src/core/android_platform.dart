import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.anonlisten.hollow/platform');

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

int? _cachedSdkInt;

/// The Android API level (`Build.VERSION.SDK_INT`), cached after the first
/// call. Null off Android or if the query fails. Prime it once at startup so
/// synchronous callers (see [AndroidScreenAudioSupport]) have it ready.
Future<int?> androidSdkInt() async {
  if (!_isAndroid) return null;
  if (_cachedSdkInt != null) return _cachedSdkInt;
  try {
    _cachedSdkInt = await _channel.invokeMethod<int>('getSdkInt');
  } catch (_) {}
  return _cachedSdkInt;
}

/// The cached API level, or null if [androidSdkInt] hasn't resolved yet.
/// Synchronous — for UI that already primed the cache.
int? get androidSdkIntCached => _cachedSdkInt;

/// Opens the system notification settings page for Hollow. False off Android
/// or when the OS refused to show it.
Future<bool> openAndroidNotificationSettings() async {
  if (!_isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('openNotificationSettings') ??
        false;
  } catch (_) {
    return false;
  }
}

/// The package that installed this APK (`com.android.vending` for Play), or
/// null off Android, on a sideload that reports nothing, or on failure. A store
/// always reports its own package, so null means "not a store".
Future<String?> androidInstallerPackage() async {
  if (!_isAndroid) return null;
  try {
    return await _channel.invokeMethod<String>('getInstallerPackage');
  } catch (_) {
    return null;
  }
}

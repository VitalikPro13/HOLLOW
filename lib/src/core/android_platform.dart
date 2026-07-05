import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.anonlisten.hollow/platform');

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

int? _cachedSdkInt;

/// The Android API level (`Build.VERSION.SDK_INT`), e.g. 24 = Android 7.0,
/// 29 = Android 10. Cached after the first call (it never changes at runtime).
/// Returns null off Android or if the query fails. Prime it once at startup so
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

Future<bool> isBatteryOptimized() async {
  if (!_isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('isBatteryOptimized') ?? false;
  } catch (_) {
    return false;
  }
}

Future<void> requestBatteryExemption() async {
  if (!_isAndroid) return;
  try {
    await _channel.invokeMethod<void>('requestBatteryExemption');
  } catch (_) {}
}

Future<void> acquireWifiLock() async {
  if (!_isAndroid) return;
  try {
    await _channel.invokeMethod<void>('acquireWifiLock');
  } catch (_) {}
}

Future<void> releaseWifiLock() async {
  if (!_isAndroid) return;
  try {
    await _channel.invokeMethod<void>('releaseWifiLock');
  } catch (_) {}
}

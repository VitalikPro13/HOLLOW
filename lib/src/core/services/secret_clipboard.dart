import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Copies a secret (the recovery phrase, a redeem code) so it does not linger:
/// Android 13+ marks the clip sensitive, iOS keeps it off other devices and
/// expires it, and everywhere it is cleared after [clearAfter] if the
/// clipboard still holds it. Whatever the person copied since is left alone.
class SecretClipboard {
  SecretClipboard._();

  static const clearAfter = Duration(seconds: 60);

  static const _channel = MethodChannel('hollow/privacy');

  /// Lets a test take the desktop path whatever the host.
  @visibleForTesting
  static TargetPlatform? debugPlatform;

  static Timer? _timer;
  static AppLifecycleListener? _onResume;

  static bool get _android =>
      (debugPlatform ?? (Platform.isAndroid ? TargetPlatform.android : null)) ==
      TargetPlatform.android;
  static bool get _ios =>
      (debugPlatform ?? (Platform.isIOS ? TargetPlatform.iOS : null)) ==
      TargetPlatform.iOS;

  static Future<void> copy(String secret) async {
    _timer?.cancel();
    _onResume?.dispose();
    _onResume = null;
    if (_ios) {
      // UIPasteboard expires it itself, and reading it back would make iOS
      // ask the person for paste permission.
      if (await _native('copySecret', {
        'text': secret,
        'seconds': clearAfter.inSeconds,
      })) {
        return;
      }
      await Clipboard.setData(ClipboardData(text: secret));
      return;
    }
    if (!(_android && await _native('copySecret', {'text': secret}))) {
      await Clipboard.setData(ClipboardData(text: secret));
    }
    _timer = Timer(clearAfter, () => _clearIfStillHeld(secret));
  }

  static Future<void> _clearIfStillHeld(String secret) async {
    if (_android) {
      // The label marks our clip, so nothing is read back; a backgrounded app
      // cannot see the clipboard at all, and then it is checked on return.
      final result = await _nativeResult('clearSecret');
      if (result == 'unknown') _retryOnResume(secret);
      return;
    }
    try {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == secret) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    } catch (e) {
      debugPrint('[HOLLOW-CLIPBOARD] clear failed: $e');
    }
  }

  static void _retryOnResume(String secret) {
    _onResume?.dispose();
    _onResume = AppLifecycleListener(onResume: () {
      _onResume?.dispose();
      _onResume = null;
      unawaited(_clearIfStillHeld(secret));
    });
  }

  static Future<bool> _native(String method, Map<String, Object> args) async {
    try {
      return await _channel.invokeMethod<bool>(method, args) ?? false;
    } catch (e) {
      debugPrint('[HOLLOW-CLIPBOARD] $method unavailable: $e');
      return false;
    }
  }

  static Future<String?> _nativeResult(String method) async {
    try {
      return await _channel.invokeMethod<String>(method);
    } catch (e) {
      debugPrint('[HOLLOW-CLIPBOARD] $method unavailable: $e');
      return null;
    }
  }
}

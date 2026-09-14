import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:window_manager/window_manager.dart';

/// How the window goes fullscreen on this platform.
enum FullscreenBackend { native, windowManager, none }

/// The runner's own channel; this file is the only caller, and the only place
/// in `lib/` allowed to call `windowManager.setFullScreen` (both CI-guarded).
const MethodChannel _windowChannel = MethodChannel('hollow/window');

/// Pure decision so a unit test can pin it: Windows = the runner's own method
/// (window_manager's SetFullScreen is a no-op on a frameless window), macOS and
/// Linux = window_manager, mobile = none (rotation is the media route's job).
FullscreenBackend fullscreenBackendFor({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
}) {
  if (isWindows) return FullscreenBackend.native;
  if (isMacOS || isLinux) return FullscreenBackend.windowManager;
  return FullscreenBackend.none;
}

/// True while the window covers its monitor. The title bar and the resize
/// edges read this, so it must never claim a fullscreen that did not happen.
final fullscreenProvider =
    NotifierProvider<FullscreenNotifier, bool>(FullscreenNotifier.new);

class FullscreenNotifier extends Notifier<bool> {
  /// Enter and exit are serialized through this, so a fast double toggle
  /// cannot interleave a restore with the enter it is undoing.
  Future<void> _pending = Future<void>.value();

  /// A platform call can land after the container is gone (a hot restart, or a
  /// test that ended); writing state then throws.
  bool _disposed = false;

  static FullscreenBackend get _backend => fullscreenBackendFor(
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
        isLinux: Platform.isLinux,
      );

  static bool get supported => _backend != FullscreenBackend.none;

  @override
  bool build() {
    // The lock cover is the app's "show nothing" state, and a window still
    // covering the monitor would sit in front of the taskbar.
    ref.listen<bool>(appLockedProvider, (previous, next) {
      if (next) unawaited(exit());
    });
    ref.onDispose(() => _disposed = true);
    return false;
  }

  /// True when the window is fullscreen afterwards.
  Future<bool> enter() => _queue(() async {
        if (!supported) return false;
        final ok = await _apply(true);
        _set(ok);
        return ok;
      });

  /// Idempotent: exiting a window that never entered still asks the platform,
  /// so a state that drifted out of sync heals instead of sticking.
  Future<void> exit() async {
    await _queue(() async {
      if (!supported) return false;
      await _apply(false);
      _set(false);
      return false;
    });
  }

  Future<void> toggle() async {
    if (state) {
      await exit();
    } else {
      await enter();
    }
  }

  void _set(bool value) {
    if (_disposed) return;
    state = value;
  }

  Future<bool> _apply(bool on) async {
    switch (_backend) {
      case FullscreenBackend.native:
        final method = on ? 'enterFullscreen' : 'exitFullscreen';
        return await _windowChannel.invokeMethod<bool>(method) ?? false;
      case FullscreenBackend.windowManager:
        await windowManager.setFullScreen(on);
        return on;
      case FullscreenBackend.none:
        return false;
    }
  }

  /// Runs [step] after whatever is already in flight. A failure leaves the
  /// window boxed, and never reaches the key handler that asked.
  Future<bool> _queue(Future<bool> Function() step) async {
    final previous = _pending;
    final done = Completer<void>();
    _pending = done.future;
    try {
      await previous;
      return await step();
    } catch (e) {
      debugPrint('[HOLLOW] fullscreen failed: $e');
      _set(false);
      try {
        await _apply(false);
      } catch (_) {
        // Best effort: the window is already in whatever state it is in.
      }
      return false;
    } finally {
      done.complete();
    }
  }
}

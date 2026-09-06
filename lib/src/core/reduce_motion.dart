import 'package:flutter/widgets.dart';

import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Tri-state reduce-motion preference: [auto] follows the OS accessibility
/// flag, [on] and [off] override it.
///
/// Persisted under `reduce_motion_mode`. The legacy `disable_animations` bool
/// migrates to [on] when it was true, else [auto].
enum ReduceMotionMode {
  auto,
  on,
  off;

  static ReduceMotionMode fromKey(String? value) {
    switch (value) {
      case 'on':
        return ReduceMotionMode.on;
      case 'off':
        return ReduceMotionMode.off;
      case 'auto':
        return ReduceMotionMode.auto;
      default:
        return ReduceMotionMode.auto;
    }
  }

  String get key => name;
}

/// The single source of truth for whether motion is currently reduced.
///
/// Owns both legacy statics ([HollowDurations.animationsDisabled] and
/// [SharedTickers.instance.disabled]), which used to be hand-synced in three
/// files. Effective = mode is [on], or mode is [auto] and the OS flag is set.
/// Listens to [PlatformDispatcher.onAccessibilityFeaturesChanged] so an OS
/// flip takes effect live; [effective] is a [ValueListenable] widgets can watch.
class ReduceMotionController {
  ReduceMotionController._();

  static final ReduceMotionController instance = ReduceMotionController._();

  /// The in-app override. Starts at [ReduceMotionMode.auto] so the OS flag
  /// governs until the persisted value is loaded after unlock.
  ReduceMotionMode _mode = ReduceMotionMode.auto;

  /// The current effective reduce-motion state. Reactive so widgets that can't
  /// read the statics (route builders, say) rebuild when it changes.
  final ValueNotifier<bool> effective = ValueNotifier<bool>(false);

  bool _osReduceMotion = false;
  bool _started = false;

  /// Seed from the OS flag and wire the runtime listener. Safe before the DB
  /// opens. Call once in `main()` BEFORE [SharedTickers.instance.start] so
  /// decorative tickers never spin on the login screen with Reduce Motion on.
  void initFromOs() {
    if (_started) return;
    _started = true;
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    _osReduceMotion = dispatcher.accessibilityFeatures.disableAnimations;
    // Chain any existing callback so we don't clobber it.
    final previous = dispatcher.onAccessibilityFeaturesChanged;
    dispatcher.onAccessibilityFeaturesChanged = () {
      previous?.call();
      _osReduceMotion =
          WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
              .disableAnimations;
      _recompute();
    };
    _recompute();
  }

  /// Apply the persisted (or user-changed) in-app override. Called after the DB
  /// opens and whenever the Accessibility setting changes.
  void setMode(ReduceMotionMode mode) {
    _mode = mode;
    _recompute();
  }

  ReduceMotionMode get mode => _mode;

  /// Whether motion is reduced right now. Mirror of [effective.value].
  bool get isReduced => effective.value;

  void _recompute() {
    final next = _mode == ReduceMotionMode.on ||
        (_mode == ReduceMotionMode.auto && _osReduceMotion);
    if (next == effective.value && _started) {
      // No change in effective state, but the statics must agree on the first call.
    }
    effective.value = next;

    // Drive the two legacy statics + the ticker so every existing call site
    // (duration getters, repeating tickers) sees the change without edits.
    HollowDurations.animationsDisabled = next;
    SharedTickers.instance.disabled = next;
    if (next) {
      SharedTickers.instance.pause();
    } else {
      // start() is a no-op if already running; resume() restarts a paused ticker.
      SharedTickers.instance.start();
      SharedTickers.instance.resume();
    }
  }
}

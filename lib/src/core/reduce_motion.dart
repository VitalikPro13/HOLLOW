import 'package:flutter/widgets.dart';

import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Tri-state reduce-motion preference.
///
/// - [auto]: follow the OS "Reduce Motion" accessibility flag.
/// - [on]: always reduce motion regardless of the OS flag.
/// - [off]: never reduce motion regardless of the OS flag.
///
/// Persisted under the `reduce_motion_mode` setting key. The legacy
/// `disable_animations` bool migrates to [on] (if it was true) or [auto].
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
/// Decision C of the accessibility plan: there used to be two hand-synced
/// statics ([HollowDurations.animationsDisabled] and
/// [SharedTickers.instance.disabled]) written in three different files. This
/// controller owns both. It combines the OS accessibility flag with the
/// in-app override:
///
/// ```
/// effective = (mode == on)
///           || (mode == auto && OS Reduce-Motion is set)
/// ```
///
/// It listens to [PlatformDispatcher.onAccessibilityFeaturesChanged] so that
/// flipping the OS setting while the app is open takes effect live (no
/// restart). Widgets that need to rebuild on a change can listen to
/// [effective] (a [ValueListenable]).
class ReduceMotionController {
  ReduceMotionController._();

  static final ReduceMotionController instance = ReduceMotionController._();

  /// The in-app override. Starts at [ReduceMotionMode.auto] so the OS flag
  /// governs until the persisted value is loaded after unlock.
  ReduceMotionMode _mode = ReduceMotionMode.auto;

  /// The current effective reduce-motion state. Reactive so widgets that
  /// can't read the statics (e.g. route builders deciding on a transition)
  /// can rebuild when it changes.
  final ValueNotifier<bool> effective = ValueNotifier<bool>(false);

  bool _osReduceMotion = false;
  bool _started = false;

  /// Seed from the OS flag and wire the runtime listener. Safe to call before
  /// the DB opens — [PlatformDispatcher.accessibilityFeatures] is available
  /// immediately at startup. Call once in `main()` BEFORE
  /// [SharedTickers.instance.start] so decorative tickers never spin on the
  /// login screen when the OS has Reduce Motion on.
  void initFromOs() {
    if (_started) return;
    _started = true;
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    _osReduceMotion = dispatcher.accessibilityFeatures.disableAnimations;
    // Fires at runtime when the user flips OS Reduce Motion (or other a11y
    // features). Chain any existing callback so we don't clobber it.
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

  /// Apply the persisted (or user-changed) in-app override. Called after the
  /// DB opens (with the loaded value) and whenever the Accessibility setting
  /// changes.
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
      // No change in effective state — but still ensure statics agree on the
      // very first call (effective starts false; if next is also false the
      // statics may already be correct, so this is cheap).
    }
    effective.value = next;

    // Drive the two legacy statics + the ticker so every existing call site
    // (duration getters, repeating tickers) sees the change without edits.
    HollowDurations.animationsDisabled = next;
    SharedTickers.instance.disabled = next;
    if (next) {
      SharedTickers.instance.pause();
    } else {
      // Re-arm and resume. start() is a no-op if already running; resume()
      // restarts a paused ticker.
      SharedTickers.instance.start();
      SharedTickers.instance.resume();
    }
  }
}

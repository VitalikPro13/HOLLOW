import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Centralized animation clocks shared across the entire app.
///
/// Instead of each widget spawning its own [AnimationController] + [Ticker]
/// for repeating animations (shimmer sweeps, pulse glows, ambient drift),
/// all widgets read from a small set of shared [ValueNotifier]s driven by
/// two timers.
///
/// Deliberately timers and NOT tickers: a running [Ticker] is a standing
/// request for a frame every vsync, and on this stack a frame is expensive
/// even when nothing in it changed. See [_tickIntervalMs].
///
/// Benefits:
/// - N tickers → 1 clock per rate (CPU savings scale with the number of
///   visible animated widgets).
/// - Single call to [pause] / [resume] stops ALL decorative animations
///   when the window is hidden, minimized, or unfocused.
///
/// Usage:
///   Initialize once in main():
///     SharedTickers.instance.start();
///
///   In widgets (use ValueListenableBuilder or listen manually):
///     `ValueListenableBuilder<double>`(
///       valueListenable: SharedTickers.instance.shimmer,
///       builder: (_, value, child) => ...,
///     );
///
///   When app goes to tray / loses focus:
///     SharedTickers.instance.pause();
///   When app comes back:
///     SharedTickers.instance.resume();
class SharedTickers with WidgetsBindingObserver {
  SharedTickers._();

  static final SharedTickers instance = SharedTickers._();

  // ── Shared value notifiers (0.0 → 1.0 repeating) ──

  // ── FAST lane: motion you can see step ──

  /// 4-second shimmer sweep cycle (used by SelectionShimmer,
  /// _ShimmerDivider, _SectionDivider glow).
  late final shimmer = GatedNotifier(_syncFast);

  /// 1.2-second typing dots cycle (used by TypingDots).
  late final typingDots = GatedNotifier(_syncFast);

  // ── SLOW lane: motion too slow for anyone to see step ──

  /// 45-second ambient drift cycle (used by AmbientBackground).
  ///
  /// Stays on the slow lane deliberately. Over 45 seconds, one step per
  /// second moves each blob 1/45th of its path — smaller than the blur on its
  /// own edge. Running it at 30fps would buy nothing anybody can see and cost
  /// 30x the frames.
  late final ambient = GatedNotifier(_syncSlow);

  // ── Internal state ──

  Timer? _ticker;
  final _tickerStopwatch = Stopwatch();
  Timer? _ambientTimer;
  bool _running = false;
  bool _paused = false;

  /// When true, [start] and [resume] are no-ops — all decorative animations
  /// stay frozen. Set before [start] on app launch, or toggled at runtime
  /// from the "Disable Animations" setting.
  bool disabled = false;

  // Cycle durations in microseconds for precision.
  static const _shimmerCycleUs = 4000000; // 4s
  static const _typingCycleUs = 1200000; // 1.2s
  static const _ambientCycleUs = 45000000; // 45s

  /// Publish rates for the two lanes.
  ///
  /// Neither is a [Ticker], and that is the point. A running Ticker asks for a
  /// frame at every vsync whether or not the picture changed, and on Windows
  /// that is expensive: Impeller renders through ANGLE, so each frame's GL
  /// commands are translated to D3D11 on the CPU. Measured on an idle Home
  /// screen against a 240Hz display, a single always-running Ticker held the
  /// app at **fps=240 and 69% of one core**. A timer publishes at a rate we
  /// choose instead of one the monitor chooses.
  ///
  /// 30fps for motion you would notice stepping; 1fps for motion you would
  /// not. Both are gated on having listeners — see [_syncFast].
  static const _fastIntervalMs = 33; // ~30fps
  static const _slowIntervalMs = 1000; // 1fps

  /// Start the shared ticker. Call once at app startup.
  /// No-ops if [disabled] is true.
  void start() {
    if (_running || disabled) return;
    _running = true;

    // Register for lifecycle events (app pause/resume on mobile).
    WidgetsBinding.instance.addObserver(this);

    _syncFast();
    _syncSlow();
  }

  /// Whether a lane may run at all right now.
  bool get _live => _running && !_paused && !disabled;

  /// Run the fast lane only while something is listening to it.
  ///
  /// This is what keeps an idle Home screen cheap. The shimmer is on the
  /// SELECTED row and the member-panel divider; the typing dots exist only
  /// while somebody is typing. On a screen showing neither, a 30fps clock
  /// would be 30 frames a second rendered so that nothing could change.
  void _syncFast() {
    final wanted = _live && (shimmer.isWatched || typingDots.isWatched);
    if (wanted == (_ticker != null)) return;
    if (!wanted) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    if (!_tickerStopwatch.isRunning) _tickerStopwatch.start();
    _ticker = Timer.periodic(
      const Duration(milliseconds: _fastIntervalMs),
      (_) => _onTick(),
    );
  }

  void _onTick() {
    final us = _tickerStopwatch.elapsedMicroseconds;

    // Shimmer: linear 0→1 over 4s, repeating.
    shimmer.value = (us % _shimmerCycleUs) / _shimmerCycleUs;

    // Typing dots: linear 0→1 over 1.2s, repeating.
    typingDots.value = (us % _typingCycleUs) / _typingCycleUs;
  }

  void _syncSlow() {
    final wanted = _live && ambient.isWatched;
    if (wanted == (_ambientTimer != null)) return;
    if (!wanted) {
      _ambientTimer?.cancel();
      _ambientTimer = null;
      return;
    }
    _ambientTimer = Timer.periodic(
      const Duration(milliseconds: _slowIntervalMs),
      _onAmbientTick,
    );
  }

  // Track ambient phase manually since Timer doesn't give elapsed.
  final _ambientStopwatch = Stopwatch();

  void _onAmbientTick(Timer _) {
    if (!_ambientStopwatch.isRunning) _ambientStopwatch.start();
    final us = _ambientStopwatch.elapsedMicroseconds;
    ambient.value = (us % _ambientCycleUs) / _ambientCycleUs;
  }

  /// Pause all decorative animations (window hidden / tray / unfocused).
  void pause() {
    if (_paused) return;
    _paused = true;
    _tickerStopwatch.stop();
    _ambientStopwatch.stop();
    _syncFast();
    _syncSlow();
  }

  /// Resume all decorative animations (window shown / focused).
  /// No-ops if [disabled] is true.
  void resume() {
    if (!_paused || disabled) return;
    _paused = false;
    // The elapsed clocks keep their phase across a pause, so an animation
    // picks up where it left off instead of snapping back to the start.
    _tickerStopwatch.start();
    _ambientStopwatch.start();
    _syncFast();
    _syncSlow();
  }

  bool get isPaused => _paused;

  // ── WidgetsBindingObserver ──

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        pause();
        break;
      case AppLifecycleState.resumed:
        resume();
        break;
      case AppLifecycleState.inactive:
        // Keep running when just losing focus (e.g., dialog overlay).
        break;
    }
  }
}

/// A [ValueNotifier] that tells its owner when it goes from unwatched to
/// watched and back.
///
/// This is what lets a shared clock stop when nothing is listening. Without
/// it, every screen pays for every animation in the app, including the ones
/// that are not on it: the shimmer runs on a Home screen with no selected
/// row, the typing dots run when nobody is typing. With it, a clock is a cost
/// only while something is actually being drawn by it.
class GatedNotifier extends ValueNotifier<double> {
  GatedNotifier(this._onGateChanged) : super(0.0);

  final void Function() _onGateChanged;

  /// Whether anything is currently listening.
  bool get isWatched => hasListeners;

  @override
  void addListener(VoidCallback listener) {
    final had = hasListeners;
    super.addListener(listener);
    if (!had) _onGateChanged();
  }

  @override
  void removeListener(VoidCallback listener) {
    final had = hasListeners;
    super.removeListener(listener);
    if (had && !hasListeners) _onGateChanged();
  }
}

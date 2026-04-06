import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Centralized animation tickers shared across the entire app.
///
/// Instead of each widget spawning its own [AnimationController] + ticker
/// for repeating animations (shimmer sweeps, pulse glows, ambient drift),
/// all widgets read from a small set of shared [ValueNotifier]s driven by
/// a single [Ticker].
///
/// Benefits:
/// - N tickers → 1 ticker per animation type (CPU savings scale with
///   number of visible animated widgets).
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

  /// 4-second shimmer sweep cycle (used by SelectionShimmer,
  /// _ShimmerDivider, _SectionDivider glow).
  final shimmer = ValueNotifier<double>(0.0);

  /// 3-second breathing pulse cycle with easeInOut curve,
  /// ping-pong 0→1→0 (used by StatusDot).
  final pulse = ValueNotifier<double>(0.0);

  /// 1.2-second typing dots cycle (used by TypingDots).
  final typingDots = ValueNotifier<double>(0.0);

  // ── Ambient background (reduced framerate) ──

  /// 45-second ambient drift cycle at ~15fps (used by AmbientBackground).
  final ambient = ValueNotifier<double>(0.0);

  // ── Internal state ──

  Ticker? _ticker;
  Timer? _ambientTimer;
  bool _running = false;
  bool _paused = false;

  // Cycle durations in microseconds for precision.
  static const _shimmerCycleUs = 4000000; // 4s
  static const _pulseCycleUs = 6000000; // 3s × 2 (ping-pong)
  static const _typingCycleUs = 1200000; // 1.2s
  static const _ambientCycleUs = 45000000; // 45s

  /// Start the shared ticker. Call once at app startup.
  void start() {
    if (_running) return;
    _running = true;

    // Register for lifecycle events (app pause/resume on mobile).
    WidgetsBinding.instance.addObserver(this);

    _startTicker();
    _startAmbientTimer();
  }

  void _startTicker() {
    _ticker = Ticker(_onTick);
    _ticker!.start();
  }

  void _onTick(Duration elapsed) {
    final us = elapsed.inMicroseconds;

    // Shimmer: linear 0→1 over 4s, repeating.
    shimmer.value = (us % _shimmerCycleUs) / _shimmerCycleUs;

    // Pulse: ping-pong 0→1→0 over 6s total (3s each direction)
    // with easeInOut curve applied.
    final pulseLinear = (us % _pulseCycleUs) / _pulseCycleUs;
    // Convert linear ping-pong to 0→1→0.
    final pingPong = pulseLinear < 0.5
        ? pulseLinear * 2.0 // 0→1
        : 2.0 - pulseLinear * 2.0; // 1→0
    // Apply easeInOut curve.
    pulse.value = Curves.easeInOut.transform(pingPong);

    // Typing dots: linear 0→1 over 1.2s, repeating.
    typingDots.value = (us % _typingCycleUs) / _typingCycleUs;
  }

  void _startAmbientTimer() {
    // ~15fps = ~67ms interval.
    _ambientTimer = Timer.periodic(
      const Duration(milliseconds: 67),
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
    _ticker?.stop();
    _ambientTimer?.cancel();
    _ambientStopwatch.stop();
  }

  /// Resume all decorative animations (window shown / focused).
  void resume() {
    if (!_paused) return;
    _paused = false;
    // Recreate ticker (Ticker can't restart once stopped).
    _ticker?.dispose();
    _startTicker();
    _ambientStopwatch.start();
    _startAmbientTimer();
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

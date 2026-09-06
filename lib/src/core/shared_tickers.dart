import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Centralized animation clocks shared across the entire app: one timer drives
/// a small set of [ValueNotifier]s instead of every widget owning an
/// [AnimationController] + [Ticker].
///
/// Deliberately timers and NOT tickers: a running [Ticker] is a standing
/// request for a frame every vsync, and on this stack a frame is expensive
/// even when nothing in it changed. See [_fastIntervalMs].
///
/// [pause] / [resume] stop ALL decorative animation when the window is
/// hidden, minimized or unfocused. Start once from main().
class SharedTickers with WidgetsBindingObserver {
  SharedTickers._();

  static final SharedTickers instance = SharedTickers._();

  /// 4-second shimmer sweep cycle.
  late final shimmer = GatedNotifier(_syncFast);

  /// 1.2-second typing dots cycle (used by TypingDots).
  late final typingDots = GatedNotifier(_syncFast);

  /// 45-second ambient drift cycle (the mobile Chats header glow reads it at
  /// 4.5x for a ~10s sweep).
  ///
  /// Must not run on a slow clock: a sine is fastest through the middle of its
  /// travel and the pane is the widest surface in the app, so a step there is a
  /// visible jump of a soft edge, and a stutter reads as a slow app.
  late final ambient = GatedNotifier(_syncFast);

  Timer? _ticker;
  final _tickerStopwatch = Stopwatch();
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

  /// The one publish rate.
  ///
  /// A timer and not a [Ticker], and that is the point: a running Ticker asks
  /// for a frame at every vsync whether or not the picture changed. Measured on
  /// an idle Home screen against a 240Hz display, one always-running Ticker held
  /// the app at fps=240 and 69% of one core.
  ///
  /// One rate, 30fps, gated on having listeners (see [_syncFast]). The saving is
  /// in the gate and in not being a Ticker, not in running motion slowly.
  static const _fastIntervalMs = 33; // ~30fps

  /// Start the shared ticker. Call once at app startup.
  /// No-ops if [disabled] is true.
  void start() {
    if (_running || disabled) return;
    _running = true;

    WidgetsBinding.instance.addObserver(this);

    _syncFast();
  }

  /// Whether the clock may run at all right now.
  bool get _live => _running && !_paused && !disabled;

  /// Run the clock only while something is listening to it.
  ///
  /// This is the whole saving: on a screen with no shimmer, no typing dots and
  /// no ambient blobs, 30fps would render frames in which nothing can change.
  void _syncFast() {
    final wanted = _live &&
        (shimmer.isWatched || typingDots.isWatched || ambient.isWatched);
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

    shimmer.value = (us % _shimmerCycleUs) / _shimmerCycleUs;

    typingDots.value = (us % _typingCycleUs) / _typingCycleUs;

    ambient.value = (us % _ambientCycleUs) / _ambientCycleUs;
  }

  /// Pause all decorative animations (window hidden / tray / unfocused).
  void pause() {
    if (_paused) return;
    _paused = true;
    _tickerStopwatch.stop();
    _syncFast();
  }

  /// Resume all decorative animations (window shown / focused).
  /// No-ops if [disabled] is true.
  void resume() {
    if (!_paused || disabled) return;
    _paused = false;
    // The elapsed clock keeps its phase across a pause.
    _tickerStopwatch.start();
    _syncFast();
  }

  bool get isPaused => _paused;

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
/// This is what lets a shared clock stop when nothing is listening; without
/// it every screen pays for every animation in the app, including the ones
/// that are not on it.
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

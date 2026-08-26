import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Centralized animation clocks shared across the entire app.
///
/// Instead of each widget spawning its own [AnimationController] + [Ticker]
/// for repeating animations (shimmer sweeps, pulse glows, ambient drift),
/// all widgets read from a small set of shared [ValueNotifier]s driven by
/// one timer.
///
/// Deliberately timers and NOT tickers: a running [Ticker] is a standing
/// request for a frame every vsync, and on this stack a frame is expensive
/// even when nothing in it changed. See [_fastIntervalMs].
///
/// Benefits:
/// - N tickers → one clock (CPU savings scale with the number of visible
///   animated widgets).
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
  late final shimmer = GatedNotifier(_syncFast);

  /// 1.2-second typing dots cycle (used by TypingDots).
  late final typingDots = GatedNotifier(_syncFast);

  /// 45-second ambient drift cycle (used by AmbientBackground, and by the
  /// mobile Chats header glow, which reads it at 4.5x for a ~10s sweep).
  ///
  /// This one briefly ran on a 1fps clock, on the reasoning that 1/45th of a
  /// path per step is a smaller move than the blur on the blob's own edge.
  /// That is true of the blob's AVERAGE speed and false where it matters: a
  /// sine is fastest through the middle of its travel, the pane is the widest
  /// surface in the app, so a step there is a visible jump of a soft edge. And
  /// the header glow rides the same clock at 4.5x, crossing the screen in five
  /// seconds — at 1fps that is five frames, which reads as the app dropping
  /// them. Decorative motion that steps looks like a stutter, and a stutter
  /// reads as a slow app, which is the opposite of what a cheap clock is for.
  late final ambient = GatedNotifier(_syncFast);

  // ── Internal state ──

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
  /// It is a timer and not a [Ticker], and that is the point. A running Ticker
  /// asks for a frame at every vsync whether or not the picture changed, and a
  /// frame is never free. Measured on an idle Home screen against a 240Hz
  /// display (on Impeller, which rendered through ANGLE and paid to translate
  /// each frame's GL commands to D3D11 on the CPU), a single always-running
  /// Ticker held the app at **fps=240 and 69% of one core**. A timer publishes
  /// at a rate we choose instead of one the monitor chooses.
  ///
  /// One rate, 30fps, gated on having listeners — see [_syncFast]. The saving
  /// is in the gate and in not being a Ticker, not in running visible motion
  /// slowly: this costs 30 frames a second while something on screen is drawn
  /// by it, and nothing whatsoever when there is not.
  ///
  /// The one animation that genuinely wants a slow clock keeps its own: the
  /// relay card's poll-cycle sweep in `home_dashboard.dart` steps once a
  /// second, seven steps to fill, then stops. That is a countdown, not motion,
  /// and drawing it smoothly would only make it read as a loading bar.
  static const _fastIntervalMs = 33; // ~30fps

  /// Start the shared ticker. Call once at app startup.
  /// No-ops if [disabled] is true.
  void start() {
    if (_running || disabled) return;
    _running = true;

    // Register for lifecycle events (app pause/resume on mobile).
    WidgetsBinding.instance.addObserver(this);

    _syncFast();
  }

  /// Whether the clock may run at all right now.
  bool get _live => _running && !_paused && !disabled;

  /// Run the clock only while something is listening to it.
  ///
  /// This is what keeps an idle screen cheap, and it is the whole saving. The
  /// shimmer is on the SELECTED row and the member-panel divider; the typing
  /// dots exist only while somebody is typing; the ambient blobs are hidden
  /// outright behind a custom background. On a screen showing none of them,
  /// 30fps would be 30 frames a second rendered so that nothing could change.
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

    // Shimmer: linear 0→1 over 4s, repeating.
    shimmer.value = (us % _shimmerCycleUs) / _shimmerCycleUs;

    // Typing dots: linear 0→1 over 1.2s, repeating.
    typingDots.value = (us % _typingCycleUs) / _typingCycleUs;

    // Ambient drift: linear 0→1 over 45s, repeating.
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
    // The elapsed clock keeps its phase across a pause, so an animation picks
    // up where it left off instead of snapping back to the start.
    _tickerStopwatch.start();
    _syncFast();
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

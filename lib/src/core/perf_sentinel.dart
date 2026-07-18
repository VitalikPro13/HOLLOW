import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show WebRTC;

import '../rust/api/network.dart' as network_api;

/// Self-diagnosis performance sentinels (Dart layer).
///
/// Quiet by default: sentinels emit ONLY anomalies, rate-limited or latched,
/// each line carrying the grep-able "[SENTINEL]" prefix and landing in
/// hollow_debug.log via logFromDart. A UI freeze or a slow platform-channel
/// call leaves a named, timestamped line instead of requiring a log dig.
///
/// Never log content or ids that fingerprint — sentinel lines carry only
/// durations, counters, and method names.
class PerfSentinel {
  PerfSentinel._();

  static const int frameStallMs = 100;
  static const int slowChannelMs = 50;

  static bool _initialized = false;
  static late final FrameStallAggregator _frames;
  static late final SlowCallLog _slowCalls;

  static void _emit(String line) {
    // Fire-and-forget FFI: swallow rejections here or they hit the zone
    // crash handler (see feedback_ffi_fire_and_forget_catcherror).
    network_api.logFromDart(message: line).catchError((_) {});
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// Called once from main() after RustLib.init (logFromDart must be live).
  static void init() {
    if (_initialized) return;
    _initialized = true;
    _frames = FrameStallAggregator(sink: _emit);
    _slowCalls = SlowCallLog(sink: _emit, thresholdMs: slowChannelMs);

    SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
      final now = _nowMs();
      for (final t in timings) {
        _frames.onFrame(
          t.buildDuration.inMilliseconds + t.rasterDuration.inMilliseconds,
          now,
        );
      }
    });

    // The fork funnels all ~120 native WebRTC calls through one channel
    // wrapper; it reports any call over its threshold to this hook.
    WebRTC.slowInvokeListener =
        (String method, int ms) => _slowCalls.report(method, ms, _nowMs());
  }

  /// Timed invokeMethod for services that hold their own copy of the
  /// FlutterWebRTC.Method channel (screen share / recording / screen audio)
  /// and therefore bypass the fork's funnel.
  static Future<T?> timedChannelCall<T>(
    MethodChannel channel,
    String method, [
    dynamic arguments,
  ]) async {
    final sw = Stopwatch()..start();
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } finally {
      sw.stop();
      if (_initialized) {
        _slowCalls.report(method, sw.elapsedMilliseconds, _nowMs());
      }
    }
  }
}

/// Frame-stall aggregation: a frame whose build+raster exceeds the threshold
/// logs at most one line per [lineIntervalMs]; stalls in between are counted
/// and flushed as a single summary line at most once per [flushIntervalMs].
/// Pure logic (injected clock + sink) so the rate limit is unit-testable.
class FrameStallAggregator {
  FrameStallAggregator({
    required this.sink,
    this.stallThresholdMs = PerfSentinel.frameStallMs,
    this.lineIntervalMs = 5000,
    this.flushIntervalMs = 60000,
    this.graceFrames = 30,
  });

  final void Function(String line) sink;
  final int stallThresholdMs;
  final int lineIntervalMs;
  final int flushIntervalMs;

  /// The first frames of a session always stall (initial build, shader
  /// warm-up) — not an anomaly, so they are ignored entirely.
  final int graceFrames;

  int _graceLeft = 0;
  bool _started = false;
  int _lastLineMs = 0;
  int _lastFlushMs = 0;
  int _suppressed = 0;
  int _worstSuppressedMs = 0;

  void onFrame(int frameTotalMs, int nowMs) {
    if (!_started) {
      _started = true;
      _graceLeft = graceFrames;
      _lastFlushMs = nowMs;
      // Allow the very first post-grace stall to log immediately.
      _lastLineMs = nowMs - lineIntervalMs;
    }
    if (_graceLeft > 0) {
      _graceLeft--;
      return;
    }

    if (frameTotalMs > stallThresholdMs) {
      if (nowMs - _lastLineMs >= lineIntervalMs) {
        _lastLineMs = nowMs;
        sink('[SENTINEL] frame ${frameTotalMs}ms');
      } else {
        _suppressed++;
        if (frameTotalMs > _worstSuppressedMs) {
          _worstSuppressedMs = frameTotalMs;
        }
      }
    }

    // Lazy once-a-minute flush of the suppressed-stall counter. Checked on
    // frame activity only: if no frames render, there is nothing to report.
    if (nowMs - _lastFlushMs >= flushIntervalMs) {
      if (_suppressed > 0) {
        sink('[SENTINEL] frames suppressed=$_suppressed '
            'worst=${_worstSuppressedMs}ms');
        _suppressed = 0;
        _worstSuppressedMs = 0;
      }
      _lastFlushMs = nowMs;
    }
  }
}

/// Slow platform-call log with a per-method rate limit: the first slow call
/// of a method logs immediately; repeats within [lineIntervalMs] are counted
/// and summarized on the next emitted line for that method.
class SlowCallLog {
  SlowCallLog({
    required this.sink,
    this.thresholdMs = PerfSentinel.slowChannelMs,
    this.lineIntervalMs = 5000,
  });

  final void Function(String line) sink;
  final int thresholdMs;
  final int lineIntervalMs;

  // Bounded by the number of distinct method names (~120 in the fork).
  final Map<String, _SlowCallEntry> _entries = {};

  void report(String method, int elapsedMs, int nowMs) {
    if (elapsedMs < thresholdMs) return;
    final e = _entries.putIfAbsent(method, _SlowCallEntry.new);
    if (nowMs - e.lastLineMs >= lineIntervalMs) {
      final suffix = e.suppressed > 0
          ? ' (+${e.suppressed} suppressed, worst ${e.worstMs}ms)'
          : '';
      e
        ..lastLineMs = nowMs
        ..suppressed = 0
        ..worstMs = 0;
      sink('[SENTINEL] channel $method ${elapsedMs}ms$suffix');
    } else {
      e.suppressed++;
      if (elapsedMs > e.worstMs) e.worstMs = elapsedMs;
    }
  }
}

class _SlowCallEntry {
  // Far enough in the past that the first slow call always logs.
  int lastLineMs = -1 << 48;
  int suppressed = 0;
  int worstMs = 0;
}

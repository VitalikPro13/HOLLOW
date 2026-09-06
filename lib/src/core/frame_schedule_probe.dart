import 'dart:async';

import 'package:flutter/widgets.dart';

/// Diagnostic binding that answers "who is asking for all these frames".
///
/// A Flutter app only renders when something calls `scheduleFrame()`. Nothing
/// in the normal toolkit names the caller: the frame is not slow, so no stall
/// fires, and Dart's cost is near zero, so a profiler points at the engine.
/// So this overrides [scheduleFrame], folds identical stacks and logs the
/// busiest few. It runs in RELEASE, which matters: debug mode schedules frames
/// a release build never would, and `debugPrintScheduleFrameStacks` is
/// assert-guarded. Off unless [startBurst] is called; one burst, then it disarms.
class FrameScheduleProbe extends WidgetsFlutterBinding {
  static FrameScheduleProbe? _instance;

  /// Replaces `WidgetsFlutterBinding.ensureInitialized()`.
  static FrameScheduleProbe ensureInitialized() {
    if (_instance == null) {
      FrameScheduleProbe();
      _instance = WidgetsBinding.instance as FrameScheduleProbe;
    }
    return _instance!;
  }

  bool _capturing = false;
  int _remaining = 0;
  final Map<String, int> _folded = {};
  void Function(String line)? _sink;

  /// Capture the next [samples] `scheduleFrame()` stacks, then report. [delay]
  /// exists so startup, which legitimately schedules many frames, is not measured.
  void startBurst({
    required void Function(String line) sink,
    Duration delay = const Duration(seconds: 20),
    int samples = 150,
  }) {
    Timer(delay, () {
      _sink = sink;
      _folded.clear();
      _remaining = samples;
      _capturing = true;
    });
  }

  @override
  void scheduleFrame() {
    if (_capturing) _capture();
    super.scheduleFrame();
  }

  void _capture() {
    // Frames 0-1 are this probe itself; the caller is above that. Ten frames
    // is enough to name the widget without turning one line into a page.
    final lines = StackTrace.current.toString().split('\n');
    final start = lines.length > 2 ? 2 : 0;
    final end = (start + 10).clamp(0, lines.length);
    final key = lines
        .sublist(start, end)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join(' | ');
    _folded[key] = (_folded[key] ?? 0) + 1;

    if (--_remaining > 0) return;
    _capturing = false;
    final sink = _sink;
    if (sink == null) return;
    final top = _folded.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    sink('[SENTINEL] scheduleFrame callers, top ${top.length > 3 ? 3 : top.length}'
        ' of ${_folded.length} distinct:');
    for (final e in top.take(3)) {
      sink('[SENTINEL] scheduleFrame x${e.value}: ${e.key}');
    }
  }
}

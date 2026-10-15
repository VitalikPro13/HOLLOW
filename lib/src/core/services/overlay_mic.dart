import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/services/mic_level_capture.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// What can take the microphone from "Listen to my mic now".
enum OverlayMicHold { dmCall, voiceChannel, micTest, voiceMessage }

/// The button and the capture, as the user bar and Settings show them.
@immutable
class OverlayMicStatus {
  /// The user turned listening on this session (never remembered).
  final bool on;

  /// The microphone is open for the overlay right now.
  final bool listening;

  const OverlayMicStatus({this.on = false, this.listening = false});

  /// On, but a call or the microphone test holds the mic.
  bool get paused => on && !listening;

  @override
  bool operator ==(Object other) =>
      other is OverlayMicStatus &&
      other.on == on &&
      other.listening == listening;

  @override
  int get hashCode => Object.hash(on, listening);
}

/// "Listen to my mic now" (plan 7a): lets the overlay's "just me" view react to
/// the voice with no call running, from the same raw capture as the Settings
/// microphone test.
///
/// A call never fights it for the mic: every path that opens call audio first
/// awaits [yieldToCall], which returns only once the capture has released the
/// device, and the call's teardown hands it back with [release]. Start and
/// stop run one at a time, so a yield landing mid-start waits for that start
/// and then stops it.
class OverlayMic {
  OverlayMic({
    MicLevelCapture Function()? newCapture,
    this.resumeDelay = const Duration(milliseconds: 600),
    this.stopTimeout = const Duration(milliseconds: 2500),
    DateTime Function()? now,
    void Function(String message)? log,
  })  : _newCapture = newCapture ?? MicLevelCapture.new,
        _now = now ?? DateTime.now,
        _log = log ?? _logToFile;

  /// The call path's floor, measured pre-chain like this raw capture.
  static const double defaultThresholdDb = -45.0;

  /// Between a call letting go and listening resuming. Switching voice rooms
  /// tears one call down and opens the next within it, so the mic is not
  /// reopened for a moment in between.
  final Duration resumeDelay;

  /// The longest a call waits for listening to let go of the mic.
  final Duration stopTimeout;

  final MicLevelCapture Function() _newCapture;
  final DateTime Function() _now;
  final void Function(String message) _log;

  /// The button and the capture.
  final ValueNotifier<OverlayMicStatus> status =
      ValueNotifier(const OverlayMicStatus());

  /// Speaking: the level over [thresholdDb], held for [hold] after it drops.
  final ValueNotifier<bool> speaking = ValueNotifier(false);

  /// Each chunk's RMS dBFS while listening.
  void Function(double db)? onLevelDb;

  /// The input picked in Settings; null or empty = the system default.
  Future<String?> Function()? inputDevice;

  /// The sensitivity slider.
  double thresholdDb = defaultThresholdDb;

  /// The look's hold time, so the image does not flicker between words.
  Duration hold = const Duration(milliseconds: 250);

  final Set<OverlayMicHold> _holds = {};
  MicLevelCapture? _capture;
  Timer? _resumeTimer;
  Future<void> _ops = Future<void>.value();
  DateTime? _lastLoud;

  bool get _on => status.value.on;

  Set<OverlayMicHold> get holds => Set.unmodifiable(_holds);

  /// Turns listening on. Throws when the microphone cannot be opened, and
  /// listening is off again. While something holds the mic it only records
  /// the wish: listening starts once that ends.
  Future<void> turnOn() async {
    if (!_on) _setStatus(on: true);
    await _serial(() => _startIfDue(rethrowFailure: true));
  }

  /// Turns listening off and releases the mic. Also the lock, wipe and
  /// server-off path.
  Future<void> turnOff() async {
    if (_on) _setStatus(on: false);
    await _awaitStop(_serial(_stopCapture), 'turn off');
  }

  /// Stops listening and completes once the microphone is released, so the
  /// caller's getUserMedia (or the mic test's capture) never overlaps it.
  /// Holds until [release] with the same [hold].
  Future<void> yieldToCall(OverlayMicHold hold) async {
    _holds.add(hold);
    final mention = _on || _capture != null;
    final released =
        await _awaitStop(_serial(_stopCapture), 'yield(${hold.name})');
    if (mention && released) {
      _log('[OVERLAY-MIC] yield(${hold.name}): stop completed, mic released');
    }
  }

  /// Waits at most [stopTimeout] for [stop]. A capture that will not let go
  /// (a wedged native recorder, a start stuck behind a permission prompt)
  /// never holds a call's microphone: the capture is already dropped, its
  /// late close only releases a device the call shares, and later starts
  /// still queue behind it.
  Future<bool> _awaitStop(Future<void> stop, String what) async {
    try {
      await stop.timeout(stopTimeout);
      return true;
    } on TimeoutException {
      _log('[OVERLAY-MIC] $what: the capture did not let go within '
          '${stopTimeout.inMilliseconds} ms, going ahead');
      _setStatus(listening: false);
      return false;
    }
  }

  /// [hold]'s use of the mic has fully finished (a call's teardown done, the
  /// mic test's capture stopped). Listening resumes after [resumeDelay] if it
  /// is still on and nothing else holds the mic.
  void release(OverlayMicHold hold) {
    if (!_holds.remove(hold)) return;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(resumeDelay, () {
      _resumeTimer = null;
      unawaited(_serial(() => _startIfDue(rethrowFailure: false)));
    });
  }

  /// The one gate on opening the mic: a resume timer that outlived a new
  /// hold or a turn-off lands here and opens nothing.
  Future<void> _startIfDue({required bool rethrowFailure}) async {
    if (!_on || _holds.isNotEmpty || _capture != null) return;
    final capture = _newCapture();
    _capture = capture;
    try {
      await capture.start(
        deviceId: await inputDevice?.call(),
        onChunk: (_, db) => _onLevel(db),
        log: (m) => _log('[OVERLAY-MIC] $m'),
      );
    } catch (e) {
      _capture = null;
      _log('[OVERLAY-MIC] could not open the microphone: $e');
      _setStatus(on: false);
      if (rethrowFailure) rethrow;
      return;
    }
    _setStatus(listening: true);
    _log('[OVERLAY-MIC] listening started');
  }

  Future<void> _stopCapture() async {
    final capture = _capture;
    _capture = null;
    if (capture == null) return;
    await capture.stop();
    _lastLoud = null;
    speaking.value = false;
    onLevelDb?.call(MicLevelCapture.silenceDb);
    _setStatus(listening: false);
    _log('[OVERLAY-MIC] listening stopped');
  }

  void _onLevel(double db) {
    if (_capture == null) return;
    onLevelDb?.call(db);
    final now = _now();
    if (db > thresholdDb) {
      _lastLoud = now;
      speaking.value = true;
    } else {
      final last = _lastLoud;
      if (last == null || now.difference(last) >= hold) speaking.value = false;
    }
  }

  void _setStatus({bool? on, bool? listening}) {
    status.value = OverlayMicStatus(
      on: on ?? status.value.on,
      listening: listening ?? status.value.listening,
    );
  }

  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.then((_) {}, onError: (_) {});
    return result;
  }

  static void _logToFile(String message) {
    debugPrint(message);
    try {
      network_api.logFromDart(message: message).catchError((_) {});
    } catch (_) {}
  }
}

/// The process's one listener. Call paths reach it without Riverpod: the voice
/// services gate their getUserMedia on it.
OverlayMic get overlayMic => _overlayMic;
OverlayMic _overlayMic = OverlayMic();

@visibleForTesting
set debugOverlayMic(OverlayMic mic) => _overlayMic = mic;

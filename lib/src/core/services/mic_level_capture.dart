import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/services/linux_pulse_capture.dart';
import 'package:record/record.dart' as rec;

/// Raw microphone capture outside any call: 48 kHz mono PCM16LE chunks and the
/// RMS level of each. The ONE capture path shared by the Settings microphone
/// test and listening for the stream overlay.
///
/// No WebRTC session: a loopback peer connection ran the APM at shapes that
/// never matched a real call (issue #40), and holding one would claim the
/// process-global capture chain a call needs.
class MicLevelCapture {
  MicLevelCapture({MicPcmBackend Function()? backend})
      : _newBackend = backend ?? (() => micPcmBackendFactory());

  static const int sampleRate = 48000;

  /// Floor of the 0..1 meter and of the overlay's voice level (plan 16.4).
  static const double meterFloorDb = -60.0;

  /// What a silent or empty chunk reads.
  static const double silenceDb = -100.0;

  final MicPcmBackend Function() _newBackend;
  MicPcmBackend? _backend;
  StreamSubscription<Uint8List>? _sub;

  bool get isRunning => _backend != null;

  /// Opens [deviceId] (null or empty = the system default) and calls [onChunk]
  /// per chunk with its RMS dBFS. Throws when no microphone could be opened,
  /// with nothing left running.
  Future<void> start({
    String? deviceId,
    required void Function(Uint8List chunk, double db) onChunk,
    void Function(String message)? log,
  }) async {
    if (_backend != null) throw StateError('capture already running');
    final backend = _newBackend();
    _backend = backend;
    try {
      final chunks = await backend.open(
        deviceId: (deviceId != null && deviceId.isNotEmpty) ? deviceId : null,
        sampleRate: sampleRate,
        log: log,
      );
      _sub = chunks.listen((chunk) => onChunk(chunk, rmsDbFromPcm16(chunk)),
          onError: (Object e) => log?.call('capture stream error: $e'));
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  /// Stops capture and releases the device. Completes only once the backend
  /// has let go of it, so a caller that opens the mic next never overlaps.
  Future<void> stop() async {
    final sub = _sub;
    _sub = null;
    final backend = _backend;
    _backend = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    if (backend != null) {
      try {
        await backend.close();
      } catch (_) {}
    }
  }

  /// RMS of a PCM16LE chunk in dBFS; [silenceDb] for silence or no samples.
  static double rmsDbFromPcm16(Uint8List chunk) {
    final count = chunk.length >> 1;
    if (count == 0) return silenceDb;
    final data = ByteData.sublistView(chunk);
    double sumSq = 0;
    for (var i = 0; i < count; i++) {
      final s = data.getInt16(i * 2, Endian.little).toDouble();
      sumSq += s * s;
    }
    final rms = math.sqrt(sumSq / count);
    return rms <= 1 ? silenceDb : 20.0 * math.log(rms / 32768.0) / math.ln10;
  }

  /// [db] on the 0..1 meter scale, [meterFloorDb] to 0 dBFS.
  static double barFromDb(double db) =>
      ((db - meterFloorDb) / -meterFloorDb).clamp(0.0, 1.0).toDouble();
}

/// One platform's raw PCM source. Swappable so tests never touch a device.
abstract class MicPcmBackend {
  Future<Stream<Uint8List>> open({
    String? deviceId,
    required int sampleRate,
    void Function(String message)? log,
  });

  Future<void> close();

  /// `record` on Windows and macOS; libpulse on Linux, where `record` shells
  /// out to `parecord`, which PipeWire systems do not ship.
  static MicPcmBackend forPlatform() =>
      Platform.isLinux ? _PulseBackend() : RecordPcmBackend();
}

/// `record`'s native recorders, handed out one per open capture.
///
/// On Windows a recorder is stopped and kept, never disposed: record_windows
/// 1.0.7 deletes a disposed recorder while Media Foundation's source reader
/// still holds it as its callback, and that late release then runs on freed
/// memory and kills the app (OLEAUT32!VariantClear, so-crash). The pool only
/// grows to the most captures ever open at once.
class PluginRecorders {
  PluginRecorders({rec.AudioRecorder Function()? create, bool? keepAlive})
      : _create = create ?? rec.AudioRecorder.new,
        _keepAlive = keepAlive ?? Platform.isWindows;

  final rec.AudioRecorder Function() _create;
  final bool _keepAlive;
  final List<rec.AudioRecorder> _idle = [];

  int get idleCount => _idle.length;

  rec.AudioRecorder take() => _idle.isNotEmpty ? _idle.removeLast() : _create();

  /// Stops [recorder]; completes once the plugin has let go of the device.
  Future<void> release(rec.AudioRecorder recorder) async {
    try {
      await recorder.stop();
    } catch (_) {}
    if (_keepAlive) {
      _idle.add(recorder);
      return;
    }
    try {
      await recorder.dispose();
    } catch (_) {}
  }
}

/// The process's recorders: the overlay, the mic test and voice notes.
/// Swappable in tests.
PluginRecorders pluginRecorders = PluginRecorders();

/// `record`'s PCM stream (Windows and macOS).
class RecordPcmBackend implements MicPcmBackend {
  rec.AudioRecorder? _recorder;

  @override
  Future<Stream<Uint8List>> open({
    String? deviceId,
    required int sampleRate,
    void Function(String message)? log,
  }) async {
    final recorder = _recorder ??= pluginRecorders.take();
    final base = rec.RecordConfig(
      encoder: rec.AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: sampleRate,
      device:
          deviceId == null ? null : rec.InputDevice(id: deviceId, label: ''),
    );
    try {
      return await recorder.startStream(base);
    } catch (e) {
      if (deviceId == null) rethrow;
      // The stored id may come from a different enumerator than `record`'s,
      // so the system default is the fallback.
      log?.call('startStream with device failed ($e), retrying default');
      return recorder.startStream(rec.RecordConfig(
        encoder: rec.AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: sampleRate,
      ));
    }
  }

  @override
  Future<void> close() async {
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) await pluginRecorders.release(recorder);
  }
}

class _PulseBackend implements MicPcmBackend {
  LinuxPulseCapture? _pulse;

  @override
  Future<Stream<Uint8List>> open({
    String? deviceId,
    required int sampleRate,
    void Function(String message)? log,
  }) async {
    final pulse = await LinuxPulseCapture.start(
      device: deviceId,
      sampleRate: sampleRate,
      channels: 1,
    );
    _pulse = pulse;
    return pulse.chunks;
  }

  @override
  Future<void> close() async {
    final pulse = _pulse;
    _pulse = null;
    if (pulse != null) await pulse.stop();
  }
}

/// The backend a [MicLevelCapture] opens when none is given. Swappable in tests.
@visibleForTesting
MicPcmBackend Function() micPcmBackendFactory = MicPcmBackend.forPlatform;

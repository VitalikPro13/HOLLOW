import 'dart:async';
import 'dart:typed_data';

import 'package:hollow/src/core/services/mic_level_capture.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';

/// A microphone that records when it opens and lets go, into [events], and
/// takes [closeDelay] to release the device, as a real backend does.
class FakeMic implements MicPcmBackend {
  FakeMic(this.events, {this.closeDelay = const Duration(milliseconds: 30)});

  final List<String> events;
  final Duration closeDelay;
  StreamController<Uint8List>? _chunks;
  Completer<void>? openGate;
  Object? openError;
  int opens = 0;

  bool get isOpen => _chunks != null;

  @override
  Future<Stream<Uint8List>> open({
    String? deviceId,
    required int sampleRate,
    void Function(String message)? log,
  }) async {
    opens++;
    events.add('mic-opening');
    final gate = openGate;
    if (gate != null) await gate.future;
    final error = openError;
    if (error != null) throw error;
    final chunks = StreamController<Uint8List>();
    _chunks = chunks;
    events.add('mic-open');
    return chunks.stream;
  }

  @override
  Future<void> close() async {
    final chunks = _chunks;
    _chunks = null;
    await Future<void>.delayed(closeDelay);
    await chunks?.close();
    events.add('mic-released');
  }

  /// Feeds one chunk whose samples all sit at [amplitude] (0..32767).
  void feed(int amplitude, {int samples = 480}) {
    final data = ByteData(samples * 2);
    for (var i = 0; i < samples; i++) {
      data.setInt16(i * 2, i.isEven ? amplitude : -amplitude, Endian.little);
    }
    _chunks?.add(data.buffer.asUint8List());
  }
}

/// An [OverlayMic] on [mic], resuming after [resumeDelay].
OverlayMic overlayMicOn(FakeMic mic,
        {Duration resumeDelay = const Duration(milliseconds: 20),
        DateTime Function()? now}) =>
    OverlayMic(
      newCapture: () => MicLevelCapture(backend: () => mic),
      resumeDelay: resumeDelay,
      now: now,
      log: (_) {},
    );

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Linux-only microphone capture over libpulse-simple via dart:ffi.
///
/// The `record` package's Linux backend shells out to `parecord`, which
/// PipeWire-only systems do not ship, while the PulseAudio CLIENT libraries
/// are always present and pipewire-pulse serves the same protocol, so we talk
/// to the daemon directly. The blocking pa_simple reads run in a dedicated
/// isolate and chunks arrive sized to about 100 ms, which also paces the
/// recorder UI's level meter. Device ids are PulseAudio source names, exactly
/// what the Linux device picker stores.
class LinuxPulseCapture {
  LinuxPulseCapture._(this._events, this._chunks);

  final ReceivePort _events;
  final StreamController<Uint8List> _chunks;
  Isolate? _isolate;
  SendPort? _control;
  bool _stopRequested = false;
  final _done = Completer<void>();

  /// Raw PCM16LE chunks, ~100 ms each.
  Stream<Uint8List> get chunks => _chunks.stream;

  /// Opens the capture stream and completes once audio is flowing. Throws
  /// [LinuxPulseCaptureException] when the daemon rejects the stream and the
  /// fallback to the default source also failed, or the libraries are absent.
  static Future<LinuxPulseCapture> start({
    String? device,
    int sampleRate = 16000,
    int channels = 1,
  }) async {
    final events = ReceivePort();
    final chunks = StreamController<Uint8List>();
    final capture = LinuxPulseCapture._(events, chunks);
    final ready = Completer<void>();

    events.listen((dynamic msg) {
      if (msg is SendPort) {
        capture._control = msg;
        // stop() can race the handshake — deliver the pending request.
        if (capture._stopRequested) msg.send('stop');
      } else if (msg is Uint8List) {
        if (!chunks.isClosed) chunks.add(msg);
      } else if (msg == 'ready') {
        if (!ready.isCompleted) ready.complete();
      } else if (msg is Map) {
        final error = msg['error'];
        if (error != null) {
          if (!ready.isCompleted) {
            ready.completeError(LinuxPulseCaptureException('$error'));
          } else if (!chunks.isClosed) {
            chunks.addError(LinuxPulseCaptureException('$error'));
          }
        }
        if (msg['done'] == true) {
          if (!capture._done.isCompleted) capture._done.complete();
          events.close();
          if (!chunks.isClosed) chunks.close();
        }
      }
    });

    capture._isolate = await Isolate.spawn(
      _captureMain,
      _CaptureRequest(events.sendPort, device, sampleRate, channels),
      debugName: 'pulse-capture',
    );

    try {
      await ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      await capture.stop();
      rethrow;
    }
    return capture;
  }

  /// Signals the capture isolate to stop and waits for it to wind down.
  Future<void> stop() async {
    _stopRequested = true;
    _control?.send('stop');
    if (!_done.isCompleted) {
      try {
        await _done.future.timeout(const Duration(seconds: 3));
      } catch (_) {
        // Wedged inside a blocking pulse call — cut it loose.
        _isolate?.kill(priority: Isolate.immediate);
      }
    }
    _events.close();
    if (!_chunks.isClosed) {
      await _chunks.close();
    }
  }
}

class LinuxPulseCaptureException implements Exception {
  final String message;
  const LinuxPulseCaptureException(this.message);
  @override
  String toString() => 'Pulse capture failed: $message';
}

class _CaptureRequest {
  final SendPort events;
  final String? device;
  final int sampleRate;
  final int channels;
  const _CaptureRequest(
      this.events, this.device, this.sampleRate, this.channels);
}

// pa_stream_direction_t / pa_sample_format_t values from pulse headers.
const int _paStreamRecord = 2;
const int _paSampleS16le = 3;

final class _PaSampleSpec extends Struct {
  @Int32()
  external int format;
  @Uint32()
  external int rate;
  @Uint8()
  external int channels;
}

final class _PaBufferAttr extends Struct {
  @Uint32()
  external int maxlength;
  @Uint32()
  external int tlength;
  @Uint32()
  external int prebuf;
  @Uint32()
  external int minreq;
  @Uint32()
  external int fragsize;
}

final class _PaSimple extends Opaque {}

typedef _PaSimpleNewC = Pointer<_PaSimple> Function(
    Pointer<Utf8> server,
    Pointer<Utf8> name,
    Int32 dir,
    Pointer<Utf8> dev,
    Pointer<Utf8> streamName,
    Pointer<_PaSampleSpec> ss,
    Pointer<Void> channelMap,
    Pointer<_PaBufferAttr> attr,
    Pointer<Int32> error);
typedef _PaSimpleNewDart = Pointer<_PaSimple> Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<_PaSampleSpec>,
    Pointer<Void>,
    Pointer<_PaBufferAttr>,
    Pointer<Int32>);
typedef _PaSimpleReadC = Int32 Function(
    Pointer<_PaSimple>, Pointer<Uint8>, Size, Pointer<Int32>);
typedef _PaSimpleReadDart = int Function(
    Pointer<_PaSimple>, Pointer<Uint8>, int, Pointer<Int32>);
typedef _PaSimpleFreeC = Void Function(Pointer<_PaSimple>);
typedef _PaSimpleFreeDart = void Function(Pointer<_PaSimple>);
typedef _PaStrerrorC = Pointer<Utf8> Function(Int32);
typedef _PaStrerrorDart = Pointer<Utf8> Function(int);

Future<void> _captureMain(_CaptureRequest req) async {
  final control = ReceivePort();
  var stopped = false;
  control.listen((_) => stopped = true);
  req.events.send(control.sendPort);

  Pointer<_PaSimple> pa = nullptr;
  _PaSimpleFreeDart? paFree;
  final allocated = <Pointer<NativeType>>[];
  try {
    final simpleLib = DynamicLibrary.open('libpulse-simple.so.0');
    final pulseLib = DynamicLibrary.open('libpulse.so.0');
    final paNew = simpleLib
        .lookupFunction<_PaSimpleNewC, _PaSimpleNewDart>('pa_simple_new');
    final paRead = simpleLib
        .lookupFunction<_PaSimpleReadC, _PaSimpleReadDart>('pa_simple_read');
    paFree = simpleLib
        .lookupFunction<_PaSimpleFreeC, _PaSimpleFreeDart>('pa_simple_free');
    final paStrerror =
        pulseLib.lookupFunction<_PaStrerrorC, _PaStrerrorDart>('pa_strerror');

    String describe(int code) {
      final detail = paStrerror(code);
      return detail == nullptr ? 'error code $code' : detail.toDartString();
    }

    final appName = 'Hollow'.toNativeUtf8();
    final streamName = 'voice-message'.toNativeUtf8();
    allocated.addAll([appName, streamName]);

    final spec = calloc<_PaSampleSpec>();
    allocated.add(spec);
    spec.ref
      ..format = _paSampleS16le
      ..rate = req.sampleRate
      ..channels = req.channels;

    // fragsize = one chunk, so reads tick every ~100 ms instead of the
    // server default (~2 s), which would starve the level meter.
    final chunkBytes = (req.sampleRate ~/ 10) * req.channels * 2;
    final attr = calloc<_PaBufferAttr>();
    allocated.add(attr);
    attr.ref
      ..maxlength = 0xFFFFFFFF
      ..tlength = 0xFFFFFFFF
      ..prebuf = 0xFFFFFFFF
      ..minreq = 0xFFFFFFFF
      ..fragsize = chunkBytes;

    final err = calloc<Int32>();
    allocated.add(err);

    Pointer<Utf8> devPtr = nullptr;
    final device = req.device;
    if (device != null && device.isNotEmpty) {
      devPtr = device.toNativeUtf8();
      allocated.add(devPtr);
    }

    pa = paNew(nullptr, appName, _paStreamRecord, devPtr, streamName, spec,
        nullptr, attr, err);
    if (pa == nullptr && devPtr != nullptr) {
      // The saved device may be stale/unplugged — fall back to the default
      // source rather than failing the recording outright.
      pa = paNew(nullptr, appName, _paStreamRecord, nullptr, streamName, spec,
          nullptr, attr, err);
    }
    if (pa == nullptr) {
      req.events.send({'error': 'pa_simple_new: ${describe(err.value)}'});
      return;
    }
    req.events.send('ready');

    final buf = calloc<Uint8>(chunkBytes);
    allocated.add(buf);
    while (!stopped) {
      final r = paRead(pa, buf, chunkBytes, err);
      if (r < 0) {
        req.events.send({'error': 'pa_simple_read: ${describe(err.value)}'});
        break;
      }
      req.events.send(Uint8List.fromList(buf.asTypedList(chunkBytes)));
      // Yield to the event loop so the control port's stop can be delivered.
      await Future<void>.delayed(Duration.zero);
    }
  } catch (e) {
    req.events.send({'error': '$e'});
  } finally {
    if (pa != nullptr && paFree != null) {
      paFree(pa);
    }
    for (final p in allocated) {
      calloc.free(p);
    }
    req.events.send({'done': true});
    control.close();
  }
}

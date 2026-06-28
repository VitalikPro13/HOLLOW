import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../rust/api/network.dart' as network_api;

void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// macOS 13.0–14.1 screen-share-audio SEND path.
///
/// On these versions the CoreAudio Process Tap (14.2+) isn't available, so we
/// capture system audio with ScreenCaptureKit (audio-only) in the native
/// plugin, stream raw PCM to Dart over an EventChannel, Opus-encode it with the
/// bundled `screen_audio_capturer --mode encode` helper, and hand the resulting
/// Opus packets to [onPacket] — identical to the Windows WASAPI sender, so the
/// receiver path ([ScreenAudioRenderer] / `--mode render`) is unchanged.
///
/// Pipeline:
///   SCK audio (native) --PCM--> EventChannel --> this --stdin--> encode exe
///     --stdout [len][seq][opus]--> this --> onPacket([seq][opus]) --> 0x03 DC
class MacSckScreenAudioCapturer {
  static const MethodChannel _method = MethodChannel('FlutterWebRTC.Method');
  static const EventChannel _pcmChannel =
      EventChannel('FlutterWebRTC/ScreenShareAudio');

  Process? _encoder;
  StreamSubscription? _pcmSub;
  StreamSubscription? _stdoutSub;
  bool _active = false;
  int _pcmChunks = 0;
  int _packetCount = 0;

  final BytesBuilder _buffer = BytesBuilder(copy: false);

  bool get isActive => _active;

  static String? _findEncoderPath() {
    final exe = File(Platform.resolvedExecutable);
    final contentsDir = exe.parent.parent.path; // Hollow.app/Contents
    final sep = Platform.pathSeparator;
    final candidates = <String>[
      '$contentsDir${sep}Resources${sep}screen_audio_capturer',
      '$contentsDir${sep}Resources${sep}screen_audio_test',
      // Dev fallback (built but not yet bundled).
      '${exe.parent.path}$sep..$sep..$sep..$sep..$sep..${sep}packages'
          '${sep}flutter_webrtc${sep}test_apps${sep}screen_audio_test'
          '${sep}build${sep}screen_audio_test',
    ];
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    _log('[SCK-AUDIO] No encoder binary found');
    return null;
  }

  /// Start SCK capture + the encode helper. Opus packets `[seq][opus]` are
  /// delivered via [onPacket], ready to prefix with 0x03 for the data channel.
  /// [bitrate] (bps) overrides the encoder default (128k); pass higher for more
  /// fidelity. Returns false if not on macOS, the binary is missing, or the
  /// native capture fails to start (e.g. macOS < 13.0).
  Future<bool> start({
    int bitrate = 0,
    required void Function(Uint8List packet) onPacket,
  }) async {
    if (!Platform.isMacOS) return false;
    if (_active) return true;

    final exePath = _findEncoderPath();
    if (exePath == null) {
      _log('[SCK-AUDIO] ERROR: screen_audio_capturer not found');
      return false;
    }

    // Spawn the Opus encoder helper first so it's ready for PCM.
    final args = ['--mode', 'encode'];
    if (bitrate > 0) args.addAll(['--bitrate', bitrate.toString()]);
    try {
      _encoder = await Process.start(exePath, args,
          mode: ProcessStartMode.normal);
    } catch (e) {
      _log('[SCK-AUDIO] Failed to spawn encoder: $e');
      return false;
    }

    _encoder!.stderr.transform(const SystemEncoding().decoder).listen((line) {
      for (final l in line.split('\n')) {
        final t = l.trim();
        if (t.isNotEmpty) _log('[SCK-AUDIO-ENC] $t');
      }
    });
    _encoder!.exitCode.then((code) {
      _log('[SCK-AUDIO] Encoder exited ($code)');
      _active = false;
    });

    // Read framed Opus packets from the encoder's stdout.
    _packetCount = 0;
    _stdoutSub = _encoder!.stdout.listen((chunk) {
      _buffer.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      _drainFrames(onPacket);
    }, onError: (e) => _log('[SCK-AUDIO] stdout error: $e'));

    // Start native SCK capture; PCM arrives on the event channel.
    try {
      final ok = await _method.invokeMethod<bool>('startScreenShareAudioCapture');
      if (ok != true) {
        _log('[SCK-AUDIO] Native capture returned false');
        await _teardown();
        return false;
      }
    } on PlatformException catch (e) {
      _log('[SCK-AUDIO] Native capture failed: ${e.code} ${e.message}');
      await _teardown();
      return false;
    } catch (e) {
      // Any other throw (MissingPluginException, TimeoutException, …) must also
      // tear down the already-spawned encoder process + its stdout subscription,
      // or they leak (the encoder OS process keeps running).
      _log('[SCK-AUDIO] Native capture failed (non-platform): $e');
      await _teardown();
      return false;
    }

    _active = true;
    _pcmChunks = 0;
    _pcmSub = _pcmChannel.receiveBroadcastStream().listen((event) {
      if (!_active || _encoder == null) return;
      if (event is! Uint8List) return;
      _feedPcm(event);
    }, onError: (e) => _log('[SCK-AUDIO] PCM stream error: $e'));

    _log('[SCK-AUDIO] Capture started (encoder PID ${_encoder!.pid})');
    return true;
  }

  /// Write a PCM chunk to the encoder, length-prefixed in <=32000-byte frames
  /// (the encode mode reads a uint16 length header, so chunks must fit u16).
  void _feedPcm(Uint8List pcm) {
    final stdin = _encoder?.stdin;
    if (stdin == null) return;
    try {
      int off = 0;
      while (off < pcm.length) {
        final remaining = pcm.length - off;
        final take = remaining > 32000 ? 32000 : remaining;
        final hdr = Uint8List(2);
        hdr[0] = take & 0xFF;
        hdr[1] = (take >> 8) & 0xFF;
        stdin.add(hdr);
        stdin.add(Uint8List.sublistView(pcm, off, off + take));
        off += take;
      }
    } catch (e) {
      _log('[SCK-AUDIO] stdin write failed: $e');
      _active = false;
      return;
    }
    _pcmChunks++;
    if (_pcmChunks <= 5 || _pcmChunks % 500 == 0) {
      _log('[SCK-AUDIO] Fed PCM chunk #$_pcmChunks (${pcm.length} bytes)');
    }
  }

  /// Parse `[uint16 payload_len][payload]` frames from the encoder stdout and
  /// deliver each payload (`[seq][opus]`).
  void _drainFrames(void Function(Uint8List) onPacket) {
    final bytes = _buffer.takeBytes();
    int offset = 0;
    while (offset + 2 <= bytes.length) {
      final payloadLen = bytes[offset] | (bytes[offset + 1] << 8);
      final frameLen = 2 + payloadLen;
      if (offset + frameLen > bytes.length) break;
      final packet =
          Uint8List.sublistView(bytes, offset + 2, offset + frameLen);
      onPacket(packet);
      _packetCount++;
      if (_packetCount <= 5 || _packetCount % 500 == 0) {
        _log('[SCK-AUDIO] TX packet #$_packetCount (${packet.length} bytes)');
      }
      offset += frameLen;
    }
    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
  }

  Future<void> _teardown() async {
    try {
      await _method.invokeMethod('stopScreenShareAudioCapture');
    } catch (_) {}
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    try {
      _encoder?.stdin.close();
    } catch (_) {}
    bool exited = false;
    try {
      await _encoder?.exitCode.timeout(const Duration(seconds: 2));
      exited = true;
    } catch (_) {}
    if (!exited) _encoder?.kill();
    _encoder = null;
    _buffer.clear();
  }

  Future<void> stop() async {
    if (!_active && _encoder == null) return;
    _active = false;
    _log('[SCK-AUDIO] Stopping...');
    await _teardown();
    _log('[SCK-AUDIO] Stopped');
  }
}

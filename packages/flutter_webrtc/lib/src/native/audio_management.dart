import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track_impl.dart';
import 'utils.dart';

class NativeAudioManagement {
  static Future<void> selectAudioInput(String deviceId) async {
    await WebRTC.invokeMethod(
      'selectAudioInput',
      <String, dynamic>{'deviceId': deviceId},
    );
  }

  static Future<void> setSpeakerphoneOn(bool enable) async {
    await WebRTC.invokeMethod(
      'enableSpeakerphone',
      <String, dynamic>{'enable': enable},
    );
  }

  static Future<void> ensureAudioSession() async {
    await WebRTC.invokeMethod('ensureAudioSession');
  }

  static Future<void> setSpeakerphoneOnButPreferBluetooth() async {
    await WebRTC.invokeMethod('enableSpeakerphoneButPreferBluetooth');
  }

  /// Which output the call is ACTUALLY playing out of right now (Hollow fork
  /// addition, mobile only) — `enumerateDevices()` only reports which outputs
  /// exist, and on both platforms the OS can move the route on its own
  /// (headset hotplug, audioswitch auto-switch), so a route picker cannot
  /// derive the live route from its own last write.
  ///
  /// Android returns an `AudioDeviceKind` type name (`speaker`, `earpiece`,
  /// `wired-headset`, `bluetooth`); iOS returns the `AVAudioSessionPort`
  /// portType of the current route's first output (`Speaker`, `Receiver`,
  /// `Headphones`, `BluetoothHFP`, …). Null when unknown/unsupported.
  static Future<String?> getSelectedAudioOutput() async {
    if (kIsWeb) return null;
    try {
      final res = await WebRTC.invokeMethod('hollowSelectedAudioOutput');
      return res is String && res.isNotEmpty ? res : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> setVolume(double volume, MediaStreamTrack track) async {
    if (track.kind == 'audio') {
      if (kIsWeb) {
        final constraints = track.getConstraints();
        constraints['volume'] = volume;
        await track.applyConstraints(constraints);
      } else {
        await WebRTC.invokeMethod('setVolume', <String, dynamic>{
          'trackId': track.id,
          'volume': volume,
          'peerConnectionId':
              track is MediaStreamTrackNative ? track.peerConnectionId : null
        });
      }
    }

    return Future.value();
  }

  /// Set the post-APM capture makeup gain (Hollow fork addition).
  ///
  /// Drives a native capture-post-processor that runs AFTER WebRTC's
  /// AGC/NS/EC on the local microphone, applying makeup gain followed by a
  /// soft limiter (~-3 dBFS ceiling). [gain] is a linear multiplier
  /// (1.0 = transparent). Process-global: affects every local audio track,
  /// so a single call covers both DM calls and server voice channels. No-op
  /// on web (no native APM hook).
  static Future<void> setCaptureGain(double gain) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('setCaptureGain', <String, dynamic>{
      'gain': gain,
    });
  }

  /// Toggle the EQ+compressor+limiter voice chain in the capture
  /// post-processor (Hollow fork addition).
  ///
  /// When enabled, the processor runs a STATIC broadcast voice chain (highpass
  /// + presence EQ -> compressor -> -1 dBFS limiter) instead of the legacy
  /// flat makeup gain, and [setCaptureGain]'s value becomes an input trim
  /// (2.0 = unity). [makeupDb] is the compressor's makeup gain — the chain's
  /// loudness/"strength" knob (0 = no boost, 12 = default). [dynamicMode]
  /// enables the auto-level servo: a slow speech-gated RMS meter drives the
  /// trim so any mic lands at the calibrated level, ignoring the manual
  /// gain/strength knobs. Process-global, live mid-call. No-op on web.
  static Future<void> setVoiceEnhance(bool enabled,
      {double makeupDb = 12.0, bool dynamicMode = false}) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('setVoiceEnhance', <String, dynamic>{
      'enabled': enabled,
      'makeupDb': makeupDb,
      'dynamic': dynamicMode,
    });
  }

  /// Record the PROCESSED capture signal (post AI-NS + enhance chain —
  /// exactly what a remote peer receives pre-Opus) to a mono 16-bit WAV at
  /// [path] (Hollow fork addition, issue #40 mic test). The capture pipeline
  /// must be LIVE (a PeerConnection carrying the local track) or nothing is
  /// written. Returns true when recording started. No-op false on web.
  static Future<bool> startCaptureRecord(String path) async {
    if (kIsWeb) return false;
    final started =
        await WebRTC.invokeMethod('startCaptureRecord', <String, dynamic>{
      'path': path,
    });
    return started == true;
  }

  /// Stop the capture recording started by [startCaptureRecord] and finalize
  /// the WAV file. Safe to call when not recording. No-op on web.
  static Future<void> stopCaptureRecord() async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('stopCaptureRecord');
  }

  /// Offline-render a RAW mono 16-bit PCM WAV through a FRESH instance of
  /// the native capture chain (AI-NS + EQ + gate/upward + compressor +
  /// de-esser + limiter, dynamic servo included — the same C++ live calls
  /// run) and write the processed WAV to [outPath] (Hollow fork addition,
  /// issue #40 mic test). No live WebRTC session involved or required.
  /// Blocking work happens on a native background thread. No-op false on
  /// web.
  static Future<bool> renderVoiceWav({
    required String inPath,
    required String outPath,
    double gain = 1.0,
    bool enhance = true,
    double makeupDb = 12.0,
    bool dynamicMode = false,
    bool aiNs = false,
    int engine = nsEngineRnnoise,
  }) async {
    if (kIsWeb) return false;
    final ok = await WebRTC.invokeMethod('hollowRenderVoiceWav', {
      'inPath': inPath,
      'outPath': outPath,
      'gain': gain,
      'enhance': enhance,
      'makeupDb': makeupDb,
      'dynamic': dynamicMode,
      'aiNs': aiNs,
      'engine': engine,
    });
    return ok == true;
  }

  /// Tell the capture post-processor whether the mic is MUTED (Hollow fork
  /// addition). The APM keeps processing real mic input while the outbound
  /// track is disabled, so without this the dynamic servo adapts to whatever
  /// the room plays while muted (e.g. shared music on speakers) and the voice
  /// comes back buried on unmute. Process-global, live. No-op on web.
  static Future<void> setCaptureMuted(bool muted) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('setCaptureMuted', <String, dynamic>{
      'muted': muted,
    });
  }

  /// Tell the capture post-processor that screen-share AUDIO is active on
  /// this device — either sending a share with audio or playing a received
  /// one (Hollow fork addition). Freezes the dynamic servo for the whole
  /// share: continuous speaker/room music bleed passes the servo's speech
  /// floor and would re-calibrate the mic trim to the music, burying the
  /// voice. Process-global, live. No-op on web.
  static Future<void> setCaptureServoHold(bool hold) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('setCaptureServoHold', <String, dynamic>{
      'hold': hold,
    });
  }

  /// AI noise-suppression engine ids — MUST match hollow_dfn::EngineKind
  /// in Rust (Hollow fork addition).
  static const int nsEngineRnnoise = 0;
  static const int nsEngineDfn3 = 1;

  /// Toggle AI noise suppression at the HEAD of the capture post-processor
  /// chain (Hollow fork addition). Runs post-AEC, before the enhancement
  /// chain, via hollow_core's C ABI bound at runtime; the Rust adapter
  /// converts whatever capture shape the APM delivers (48 kHz fullband,
  /// 3-band split, 16 kHz mono). [engine] picks the suppressor —
  /// [nsEngineRnnoise] (default: instant init, trivial CPU) or
  /// [nsEngineDfn3] (higher quality, expensive init) — and a later call
  /// with a different engine performs a live swap. The first enable
  /// triggers a one-shot background engine create; frames pass through
  /// untouched until it's ready. [attenLimDb] caps the maximum suppression
  /// (100 = uncapped); [postFilterBeta] enables the model's post-filter
  /// (0 = off) — both DFN3-only. Callers must ALSO disable WebRTC's legacy
  /// NS in the getUserMedia constraints while this is on (double
  /// suppression = artifacts) — see [getNoiseSuppressAiActive] for the
  /// fallback check. Process-global, live. No-op on web.
  static Future<void> setNoiseSuppressAi(bool enabled,
      {int engine = nsEngineRnnoise,
      double attenLimDb = 100.0,
      double postFilterBeta = 0.0}) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('setNoiseSuppressAi', <String, dynamic>{
      'enabled': enabled,
      'engine': engine,
      'attenLimDb': attenLimDb,
      'postFilterBeta': postFilterBeta,
    });
  }

  /// Snapshot of the DFN3 engine state (Hollow fork addition): bool keys
  /// `available` (symbols bound), `enabled`, `ready` (model loaded),
  /// `bailed` (realtime watchdog latched bypass), `formatOk` (capture shape
  /// processable), `active` (all of the above — actually denoising), plus
  /// diagnostics `frames` (int — frames denoised this session; > 0 is the
  /// PROOF the engine is in the audio path) and `emaMs` (double — smoothed
  /// per-frame cost). Callers use this to fall back to WebRTC NS when DFN
  /// can't run here. Returns an empty map on web/unsupported.
  static Future<Map<String, dynamic>> getNoiseSuppressAiActive() async {
    if (kIsWeb) return const {};
    try {
      final res = await WebRTC.invokeMethod('getNoiseSuppressAiActive');
      if (res is Map) {
        return res.map((k, v) => MapEntry(k.toString(), v));
      }
      return const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// Live microphone loudness from the capture post-processor (Hollow fork
  /// addition) — the source for speaking indicators.
  ///
  /// Returns `levelDb` (double — a decaying peak-hold of the capture RMS in
  /// dBFS; -100 means silence) and `vad` (double — the AI denoiser's voice
  /// probability 0..1, or -1 when it isn't running). Measured on the audio
  /// thread right after the denoiser and BEFORE the voice chain, so it
  /// follows the voice rather than the auto-level servo's output target.
  ///
  /// This exists because getStats is not a usable source for the LOCAL
  /// level: `audioLevel` is only specified on media-source and inbound-rtp,
  /// and desktop reports no outgoing level at all. Process-global, so one
  /// call covers DM calls and voice channels, and it works with no peer
  /// connected. Returns an empty map on web/unsupported.
  static Future<Map<String, dynamic>> getCaptureLevel() async {
    if (kIsWeb) return const {};
    try {
      final res = await WebRTC.invokeMethod('getCaptureLevel');
      if (res is Map) {
        return res.map((k, v) => MapEntry(k.toString(), v));
      }
      return const {};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// Begin out-of-process rendering of the given REMOTE audio tracks (Hollow
  /// fork, Windows only). Each track's decoded PCM is tapped via an
  /// AudioTrackSink and forwarded to a child `render-pcm` process that plays it,
  /// while the track's in-process playout is muted (SetVolume(0)). This is used
  /// during an ENTIRE-SCREEN share with audio so the call voices render from a
  /// SEPARATE pid that the screen-audio capturer excludes (anti-echo) — while
  /// Hollow's own in-app media (same hollow.exe) is still captured.
  ///
  /// Returns the renderer child's process id (to pass to the capturer's exclude
  /// list), or 0 if it didn't start / unsupported platform. No-op (returns 0) on
  /// web and non-Windows.
  static Future<int> voiceRedirectStart(List<String> trackIds) async {
    if (kIsWeb) return 0;
    try {
      final res = await WebRTC.invokeMethod('voiceRedirectStart',
          <String, dynamic>{'trackIds': trackIds});
      if (res is Map) {
        final pid = res['pid'];
        if (pid is int) return pid;
        if (pid is num) return pid.toInt();
      }
      return 0;
    } on PlatformException {
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Stop the out-of-process voice redirect started by [voiceRedirectStart]:
  /// detaches every sink, restores in-process playout volume, and shuts the
  /// renderer child down. No-op on web / non-Windows.
  static Future<void> voiceRedirectStop() async {
    if (kIsWeb) return;
    try {
      await WebRTC.invokeMethod('voiceRedirectStop');
    } on PlatformException {
      // best-effort
    } on MissingPluginException {
      // best-effort
    }
  }

  /// Start a native PCM player for received screen-share audio (Hollow fork,
  /// mobile). Plays raw 48 kHz stereo int16 PCM on the MEDIA output path —
  /// deliberately OUTSIDE the WebRTC voice session, so the call's AEC/AGC/
  /// speech processing can't mangle the shared music. Desktop uses an
  /// out-of-process renderer exe instead; this is the Android/iOS sibling.
  /// No-op on web.
  static Future<void> startScreenAudioPlayer() async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('startScreenAudioPlayer');
  }

  /// Feed one decoded PCM buffer (interleaved 48 kHz stereo signed-16-bit LE)
  /// to the native screen-audio player started by [startScreenAudioPlayer].
  /// No-op on web. Safe to call before start (dropped natively).
  static Future<void> writeScreenAudioPcm(Uint8List pcm) async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('writeScreenAudioPcm', <String, dynamic>{
      'pcm': pcm,
    });
  }

  /// Stop and release the native screen-audio player. No-op on web.
  static Future<void> stopScreenAudioPlayer() async {
    if (kIsWeb) return;
    await WebRTC.invokeMethod('stopScreenAudioPlayer');
  }

  static Future<void> setMicrophoneMute(
      bool mute, MediaStreamTrack track) async {
    if (track.kind != 'audio') {
      throw 'The is not an audio track => $track';
    }

    if (!kIsWeb) {
      try {
        await WebRTC.invokeMethod(
          'setMicrophoneMute',
          <String, dynamic>{'trackId': track.id, 'mute': mute},
        );
      } on PlatformException catch (e) {
        throw 'Unable to MediaStreamTrack::setMicrophoneMute: ${e.message}';
      }
    }
    track.enabled = !mute;
  }

  // ADM APIs
  static Future<void> startLocalRecording() async {
    if (!kIsWeb) {
      try {
        await WebRTC.invokeMethod(
          'startLocalRecording',
          <String, dynamic>{},
        );
      } on PlatformException catch (e) {
        throw 'Unable to start local recording: ${e.message}';
      }
    }
  }

  static Future<void> stopLocalRecording() async {
    if (!kIsWeb) {
      try {
        await WebRTC.invokeMethod(
          'stopLocalRecording',
          <String, dynamic>{},
        );
      } on PlatformException catch (e) {
        throw 'Unable to stop local recording: ${e.message}';
      }
    }
  }

  static Future<bool> isVoiceProcessingEnabled() async {
    if (kIsWeb) return false;

    try {
      final result = await WebRTC.invokeMethod(
        'isVoiceProcessingEnabled',
        <String, dynamic>{},
      );
      return result as bool;
    } on PlatformException catch (e) {
      throw 'Unable to get isVoiceProcessingEnabled: ${e.message}';
    }
  }

  static Future<bool> isVoiceProcessingBypassed() async {
    if (kIsWeb) return false;

    try {
      final result = await WebRTC.invokeMethod(
        'isVoiceProcessingBypassed',
        <String, dynamic>{},
      );
      return result as bool;
    } on PlatformException catch (e) {
      throw 'Unable to get isVoiceProcessingBypassed: ${e.message}';
    }
  }

  static Future<void> setIsVoiceProcessingBypassed(bool value) async {
    if (kIsWeb) return;

    try {
      await WebRTC.invokeMethod(
        'setIsVoiceProcessingBypassed',
        <String, dynamic>{"value": value},
      );
    } on PlatformException catch (e) {
      throw 'Unable to set isVoiceProcessingBypassed: ${e.message}';
    }
  }
}

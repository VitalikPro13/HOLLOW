import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:logger/logger.dart';

import '../flutter_webrtc.dart';
import 'native_logs_listener.dart';

class Helper {
  /// Set Logger object for webrtc;
  ///
  /// Params:
  ///
  /// "severity": possible values: ['verbose', 'info', 'warning', 'error', 'none']
  static void setLogger(Logger logger, [String severity = 'none']) {
    NativeLogsListener.instance.setLogger(logger, severity);
  }

  static Future<List<MediaDeviceInfo>> enumerateDevices(String type) async {
    var devices = await navigator.mediaDevices.enumerateDevices();
    return devices.where((d) => d.kind == type).toList();
  }

  /// Return the available cameras
  ///
  /// Note: Make sure to call this gettet after
  /// navigator.mediaDevices.getUserMedia(), otherwise the devices will not be
  /// listed.
  static Future<List<MediaDeviceInfo>> get cameras =>
      enumerateDevices('videoinput');

  /// Return the available audiooutputs
  ///
  /// Note: Make sure to call this gettet after
  /// navigator.mediaDevices.getUserMedia(), otherwise the devices will not be
  /// listed.
  static Future<List<MediaDeviceInfo>> get audiooutputs =>
      enumerateDevices('audiooutput');

  /// For web implementation, make sure to pass the target deviceId
  static Future<bool> switchCamera(MediaStreamTrack track,
      [String? deviceId, MediaStream? stream]) async {
    if (track.kind != 'video') {
      throw 'The is not a video track => $track';
    }

    if (!kIsWeb) {
      return WebRTC.invokeMethod(
        'mediaStreamTrackSwitchCamera',
        <String, dynamic>{'trackId': track.id},
      ).then((value) => value ?? false);
    }

    if (deviceId == null) throw 'You need to specify the deviceId';
    if (stream == null) throw 'You need to specify the stream';

    var cams = await cameras;
    if (!cams.any((e) => e.deviceId == deviceId)) {
      throw 'The provided deviceId is not available, make sure to retreive the deviceId from Helper.cammeras()';
    }

    // stop only video tracks
    // so that we can recapture video track
    stream.getVideoTracks().forEach((track) {
      track.stop();
      stream.removeTrack(track);
    });

    var mediaConstraints = {
      'audio': false, // NO need to capture audio again
      'video': {'deviceId': deviceId}
    };

    var newStream = await openCamera(mediaConstraints);
    var newCamTrack = newStream.getVideoTracks()[0];

    await stream.addTrack(newCamTrack, addToNative: true);

    return Future.value(true);
  }

  static Future<void> setZoom(MediaStreamTrack videoTrack, double zoomLevel) =>
      CameraUtils.setZoom(videoTrack, zoomLevel);

  static Future<void> setFocusMode(
          MediaStreamTrack videoTrack, CameraFocusMode focusMode) =>
      CameraUtils.setFocusMode(videoTrack, focusMode);

  static Future<void> setFocusPoint(
          MediaStreamTrack videoTrack, Point<double>? point) =>
      CameraUtils.setFocusPoint(videoTrack, point);

  static Future<void> setExposureMode(
          MediaStreamTrack videoTrack, CameraExposureMode exposureMode) =>
      CameraUtils.setExposureMode(videoTrack, exposureMode);

  static Future<void> setExposurePoint(
          MediaStreamTrack videoTrack, Point<double>? point) =>
      CameraUtils.setExposurePoint(videoTrack, point);

  /// Used to select a specific audio output device.
  ///
  /// Note: This method is only used for Flutter native,
  /// supported on iOS/Android/macOS/Windows.
  ///
  /// Android/macOS/Windows: Can be used to switch all output devices.
  /// iOS: you can only switch directly between the
  /// speaker and the preferred device
  /// web: flutter web can use RTCVideoRenderer.audioOutput instead
  static Future<void> selectAudioOutput(String deviceId) async {
    await navigator.mediaDevices
        .selectAudioOutput(AudioOutputOptions(deviceId: deviceId));
  }

  /// Set audio input device for Flutter native
  /// Note: The usual practice in flutter web is to use deviceId as the
  /// `getUserMedia` parameter to get a new audio track and replace it with the
  ///  audio track in the original rtpsender.
  static Future<void> selectAudioInput(String deviceId) =>
      NativeAudioManagement.selectAudioInput(deviceId);

  /// Set the W3C contentHint on a native video track ('' | 'motion' |
  /// 'detail' | 'text'). 'detail'/'text' force the screencast encoding
  /// pipeline for the track's sender, 'motion' forces the camera pipeline,
  /// '' defers to the capture source's is_screencast flag.
  ///
  /// Hollow desktop (Windows/Linux) only — rides the patched libwebrtc
  /// wrapper's RTCVideoTrack::SetContentHint; other platforms have no
  /// handler and will throw [PlatformException].
  static Future<void> setVideoContentHint(
      MediaStreamTrack track, String hint) async {
    await WebRTC.invokeMethod('videoTrackSetContentHint', <String, dynamic>{
      'trackId': track.id,
      'hint': hint,
    });
  }

  /// Enable or disable speakerphone
  /// for iOS/Android only
  static Future<void> setSpeakerphoneOn(bool enable) =>
      NativeAudioManagement.setSpeakerphoneOn(enable);

  /// Ensure audio session
  /// for iOS only
  static Future<void> ensureAudioSession() =>
      NativeAudioManagement.ensureAudioSession();

  /// Enable speakerphone, but use bluetooth if audio output device available
  /// for iOS/Android only
  static Future<void> setSpeakerphoneOnButPreferBluetooth() =>
      NativeAudioManagement.setSpeakerphoneOnButPreferBluetooth();

  /// To select a a specific camera, you need to set constraints
  /// eg.
  /// var constraints = {
  ///      'audio': true,
  ///      'video': {
  ///          'deviceId': Helper.cameras[0].deviceId,
  ///          }
  ///      };
  ///
  /// var stream = await Helper.openCamera(constraints);
  ///
  static Future<MediaStream> openCamera(Map<String, dynamic> mediaConstraints) {
    return navigator.mediaDevices.getUserMedia(mediaConstraints);
  }

  /// Set the volume for Flutter native
  static Future<void> setVolume(double volume, MediaStreamTrack track) =>
      NativeAudioManagement.setVolume(volume, track);

  /// Set the post-APM capture makeup gain (Hollow fork addition).
  ///
  /// Boosts the LOCAL microphone after WebRTC's AGC/NS/EC, with a soft
  /// limiter at ~-3 dBFS so the boost can't clip. [gain] is a linear
  /// multiplier (1.0 = transparent). Process-global — one call covers all
  /// local audio tracks (DM calls + voice channels). Updates take effect
  /// live mid-call. No-op on web.
  ///
  /// Unlike [setVolume], which only scales REMOTE (received) tracks, this
  /// actually affects the outgoing/local capture path.
  static Future<void> setCaptureGain(double gain) =>
      NativeAudioManagement.setCaptureGain(gain);

  /// Toggle the EQ+compressor+limiter voice chain in the capture
  /// post-processor (Hollow fork addition). When enabled, [setCaptureGain]'s
  /// value acts as an input trim (2.0 = unity) and the chain owns the
  /// loudness; when disabled the legacy flat makeup gain applies. [makeupDb]
  /// is the chain's loudness/"strength" knob (0 = no boost, 12 = default).
  /// [dynamicMode] enables the auto-level servo (any mic converges to the
  /// calibrated speech level; manual knobs ignored). Process-global, live
  /// mid-call. No-op on web.
  static Future<void> setVoiceEnhance(bool enabled,
          {double makeupDb = 12.0, bool dynamicMode = false}) =>
      NativeAudioManagement.setVoiceEnhance(enabled,
          makeupDb: makeupDb, dynamicMode: dynamicMode);

  /// Tell the capture post-processor whether the mic is muted (Hollow fork
  /// addition) so the dynamic servo FREEZES instead of adapting to non-call
  /// audio (room music bleed) while the outbound track is disabled.
  /// Process-global, live. No-op on web.
  static Future<void> setCaptureMuted(bool muted) =>
      NativeAudioManagement.setCaptureMuted(muted);

  /// Tell the capture post-processor that screen-share audio is active on
  /// this device (sending or playing) — the dynamic servo freezes for the
  /// whole share so continuous music bleed can't re-calibrate the mic trim.
  /// Process-global, live. No-op on web.
  static Future<void> setCaptureServoHold(bool hold) =>
      NativeAudioManagement.setCaptureServoHold(hold);

  /// AI noise-suppression engine ids (Hollow fork addition).
  static const int nsEngineRnnoise = NativeAudioManagement.nsEngineRnnoise;
  static const int nsEngineDfn3 = NativeAudioManagement.nsEngineDfn3;

  /// Toggle AI noise suppression at the head of the capture chain (Hollow
  /// fork addition, post-AEC — the Krisp slot). [engine] picks RNNoise
  /// (default, instant) or DFN3 (higher quality, slow load; a later call
  /// with a different engine swaps live). Until the engine is ready frames
  /// pass through. Callers must also disable WebRTC's legacy NS in the
  /// capture constraints while this is on. Process-global, live. No-op on
  /// web.
  static Future<void> setNoiseSuppressAi(bool enabled,
          {int engine = nsEngineRnnoise,
          double attenLimDb = 100.0,
          double postFilterBeta = 0.0}) =>
      NativeAudioManagement.setNoiseSuppressAi(enabled,
          engine: engine,
          attenLimDb: attenLimDb,
          postFilterBeta: postFilterBeta);

  /// DFN3 engine status snapshot (`available`/`enabled`/`ready`/`bailed`/
  /// `formatOk`/`active` bools + `frames`/`emaMs` diagnostics) — lets
  /// callers fall back to WebRTC NS when DFN can't run on this device.
  /// Empty map on web.
  static Future<Map<String, dynamic>> getNoiseSuppressAiActive() =>
      NativeAudioManagement.getNoiseSuppressAiActive();

  /// Live microphone loudness for speaking indicators (Hollow fork
  /// addition): `levelDb` (decaying peak-hold of the capture RMS in dBFS,
  /// -100 = silence) and `vad` (AI-denoiser voice probability 0..1, -1 when
  /// it isn't running). Read off the capture post-processor, so it works
  /// with no peer connected and on platforms whose getStats carries no
  /// outgoing audio level. Empty map on web.
  static Future<Map<String, dynamic>> getCaptureLevel() =>
      NativeAudioManagement.getCaptureLevel();

  /// Start a native PCM player for received screen-share audio (Hollow fork,
  /// mobile). Plays 48 kHz stereo int16 PCM on the media output path, OUTSIDE
  /// the WebRTC voice session so the call's AEC/AGC can't mangle the shared
  /// music. Desktop uses an out-of-process renderer exe instead.
  static Future<void> startScreenAudioPlayer() =>
      NativeAudioManagement.startScreenAudioPlayer();

  /// Feed one decoded PCM buffer (interleaved 48 kHz stereo s16le) to the
  /// native screen-audio player.
  static Future<void> writeScreenAudioPcm(Uint8List pcm) =>
      NativeAudioManagement.writeScreenAudioPcm(pcm);

  /// Stop and release the native screen-audio player.
  static Future<void> stopScreenAudioPlayer() =>
      NativeAudioManagement.stopScreenAudioPlayer();

  /// Begin out-of-process rendering of the given REMOTE audio tracks (Hollow
  /// fork, Windows only) so the call voices render from a separate pid the
  /// screen-audio capturer can exclude during an entire-screen share (anti-echo
  /// without dropping Hollow's own in-app media). Returns the renderer child
  /// pid (to exclude), or 0 if not started / unsupported.
  static Future<int> voiceRedirectStart(List<String> trackIds) =>
      NativeAudioManagement.voiceRedirectStart(trackIds);

  /// Stop the out-of-process voice redirect: restores in-process playout and
  /// shuts the renderer child down.
  static Future<void> voiceRedirectStop() =>
      NativeAudioManagement.voiceRedirectStop();

  /// Set the microphone mute/unmute for Flutter native
  static Future<void> setMicrophoneMute(bool mute, MediaStreamTrack track) =>
      NativeAudioManagement.setMicrophoneMute(mute, track);

  /// Set the audio configuration to for Android.
  /// Must be set before initiating a WebRTC session and cannot be changed
  /// mid session.
  static Future<void> setAndroidAudioConfiguration(
          AndroidAudioConfiguration androidAudioConfiguration) =>
      AndroidNativeAudioManagement.setAndroidAudioConfiguration(
          androidAudioConfiguration);

  /// After Android app finishes a session, on audio focus loss, clear the active communication device.
  static Future<void> clearAndroidCommunicationDevice() =>
      WebRTC.invokeMethod('clearAndroidCommunicationDevice');

  /// Set the audio configuration for iOS
  static Future<void> setAppleAudioConfiguration(
          AppleAudioConfiguration appleAudioConfiguration) =>
      AppleNativeAudioManagement.setAppleAudioConfiguration(
          appleAudioConfiguration);

  /// Set the audio configuration for iOS
  static Future<void> setAppleAudioIOMode(AppleAudioIOMode mode,
          {bool preferSpeakerOutput = false}) =>
      AppleNativeAudioManagement.setAppleAudioConfiguration(
          AppleNativeAudioManagement.getAppleAudioConfigurationForMode(mode,
              preferSpeakerOutput: preferSpeakerOutput));

  /// Request capture permission for Android/macOS.
  ///
  /// When [fullScreenOnly] is true and running on Android 14+ (API 34), the
  /// MediaProjection consent dialog only offers entire-screen capture and the
  /// single-app option is removed (via
  /// `MediaProjectionConfig.createConfigForDefaultDisplay()`). Has no effect on
  /// older Android versions or on macOS. Defaults to false, which keeps the
  /// platform's default user-choice dialog.
  static Future<bool> requestCapturePermission(
      {bool fullScreenOnly = false}) async {
    if (WebRTC.platformIsAndroid || WebRTC.platformIsMacOS) {
      return await WebRTC.invokeMethod(
        'requestCapturePermission',
        <String, dynamic>{'fullScreenOnly': fullScreenOnly},
      );
    } else {
      throw Exception(
          'requestCapturePermission only support for Android/macOS');
    }
  }
}

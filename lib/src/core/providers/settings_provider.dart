import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Whether closing the window minimizes to system tray instead of quitting.
/// Default: true (minimize to tray).
final minimizeToTrayProvider =
    AsyncNotifierProvider<MinimizeToTrayNotifier, bool>(
        MinimizeToTrayNotifier.new);

class MinimizeToTrayNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final val = await storage_api.loadSetting(key: 'minimize_to_tray');
    return val != 'false'; // Default true.
  }

  Future<void> setEnabled(bool value) async {
    await storage_api.saveSetting(
      key: 'minimize_to_tray',
      value: value.toString(),
    );
    state = AsyncData(value);
  }
}

/// Reduce-motion preference (tri-state Auto/On/Off).
///
/// - Auto (default): follow the OS "Reduce Motion" accessibility flag.
/// - On: always reduce motion.
/// - Off: never reduce motion.
///
/// Effective reduce-motion (OS flag OR override) is owned by
/// [ReduceMotionController]; this provider just persists the user's choice and
/// pushes it into the controller. The legacy `disable_animations` bool is
/// migrated on first read: true → On, otherwise → Auto.
final reduceMotionProvider =
    AsyncNotifierProvider<ReduceMotionNotifier, ReduceMotionMode>(
        ReduceMotionNotifier.new);

class ReduceMotionNotifier extends AsyncNotifier<ReduceMotionMode> {
  @override
  Future<ReduceMotionMode> build() async {
    final raw = await storage_api.loadSetting(key: 'reduce_motion_mode');
    if (raw != null && raw.isNotEmpty) {
      final mode = ReduceMotionMode.fromKey(raw);
      ReduceMotionController.instance.setMode(mode);
      return mode;
    }
    // Migrate the legacy disable_animations bool.
    final legacy = await storage_api.loadSetting(key: 'disable_animations');
    final migrated =
        legacy == 'true' ? ReduceMotionMode.on : ReduceMotionMode.auto;
    await storage_api.saveSetting(
      key: 'reduce_motion_mode',
      value: migrated.key,
    );
    ReduceMotionController.instance.setMode(migrated);
    return migrated;
  }

  Future<void> setMode(ReduceMotionMode mode) async {
    await storage_api.saveSetting(
      key: 'reduce_motion_mode',
      value: mode.key,
    );
    ReduceMotionController.instance.setMode(mode);
    state = AsyncData(mode);
  }
}

/// Whether to reduce transparency / blur effects (accessibility).
///
/// When on, glassmorphism dialog blur drops to sigma 0 and the opt-in
/// background-image panel renders fully opaque. Persisted under
/// `reduce_transparency`. Default: false.
final reduceTransparencyProvider =
    AsyncNotifierProvider<ReduceTransparencyNotifier, bool>(
        ReduceTransparencyNotifier.new);

/// Process-wide mirror of [reduceTransparencyProvider], so top-level helpers
/// without a `ref` (e.g. `showHollowDialog`) can consult it synchronously.
/// Kept in sync by [ReduceTransparencyNotifier].
final ValueNotifier<bool> reduceTransparencyFlag = ValueNotifier<bool>(false);

class ReduceTransparencyNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final val = await storage_api.loadSetting(key: 'reduce_transparency');
    final on = val == 'true';
    reduceTransparencyFlag.value = on;
    return on;
  }

  Future<void> setEnabled(bool value) async {
    await storage_api.saveSetting(
      key: 'reduce_transparency',
      value: value.toString(),
    );
    reduceTransparencyFlag.value = value;
    state = AsyncData(value);
  }
}

/// Preferred audio input device ID. Null/empty = system default.
final audioInputDeviceProvider =
    AsyncNotifierProvider<AudioInputDeviceNotifier, String?>(
        AudioInputDeviceNotifier.new);

class AudioInputDeviceNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final val = await storage_api.loadSetting(key: 'audio_input_device');
    return (val == null || val.isEmpty) ? null : val;
  }

  Future<void> setDevice(String? deviceId) async {
    await storage_api.saveSetting(
      key: 'audio_input_device',
      value: deviceId ?? '',
    );
    state = AsyncData(deviceId);
  }
}

/// Preferred audio output device ID. Null/empty = system default.
final audioOutputDeviceProvider =
    AsyncNotifierProvider<AudioOutputDeviceNotifier, String?>(
        AudioOutputDeviceNotifier.new);

class AudioOutputDeviceNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final val = await storage_api.loadSetting(key: 'audio_output_device');
    return (val == null || val.isEmpty) ? null : val;
  }

  Future<void> setDevice(String? deviceId) async {
    await storage_api.saveSetting(
      key: 'audio_output_device',
      value: deviceId ?? '',
    );
    state = AsyncData(deviceId);
  }
}

/// Preferred camera device ID. Null/empty = system default.
final cameraDeviceProvider =
    AsyncNotifierProvider<CameraDeviceNotifier, String?>(
        CameraDeviceNotifier.new);

class CameraDeviceNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final val = await storage_api.loadSetting(key: 'camera_device');
    return (val == null || val.isEmpty) ? null : val;
  }

  Future<void> setDevice(String? deviceId) async {
    await storage_api.saveSetting(
      key: 'camera_device',
      value: deviceId ?? '',
    );
    state = AsyncData(deviceId);
  }
}

/// Outgoing image quality tier.
///
/// Controls the Rust-side WebP encoder in `image_convert::convert_to_webp_with_quality`.
/// Persisted as `image_quality` in `app_settings`. Default: balanced.
///
/// Lossless is only worth picking if you share pixel art, diagrams, or
/// screenshots with tiny text. For normal photos/artwork, Balanced is
/// indistinguishable from lossless at render sizes and ~95% smaller.
/// Small is for very tight bandwidth / quota-constrained situations.
///
/// Phase 6.75 image quality tiers.
enum ImageQuality {
  lossless('Lossless (100%)', 'Pixel-perfect: for art, diagrams, screenshots'),
  balanced('Balanced (50%)', 'Indistinguishable, ~95% smaller'),
  small('Small (30%)', 'Aggressive compression for slow connections');

  final String label;
  final String description;
  const ImageQuality(this.label, this.description);
}

final imageQualityProvider =
    AsyncNotifierProvider<ImageQualityNotifier, ImageQuality>(
        ImageQualityNotifier.new);

class ImageQualityNotifier extends AsyncNotifier<ImageQuality> {
  @override
  Future<ImageQuality> build() async {
    final val = await storage_api.loadSetting(key: 'image_quality');
    return ImageQuality.values.firstWhere(
      (q) => q.name == val,
      orElse: () => ImageQuality.balanced,
    );
  }

  Future<void> setQuality(ImageQuality quality) async {
    await storage_api.saveSetting(
      key: 'image_quality',
      value: quality.name,
    );
    state = AsyncData(quality);
  }
}

/// Audio quality preset for voice calls.
/// Controls Opus bitrate and stereo settings via SDP munging.
enum AudioQualityPreset {
  voice('Voice', 96000, false),     // 96 kbps mono — high-quality speech
  music('Music', 128000, true),     // 128 kbps stereo — CD-like quality
  hifi('Hi-Fi', 256000, true);      // 256 kbps stereo — perceptually lossless

  final String label;
  final int bitrate;    // bits per second
  final bool stereo;
  const AudioQualityPreset(this.label, this.bitrate, this.stereo);
}

final audioQualityProvider =
    AsyncNotifierProvider<AudioQualityNotifier, AudioQualityPreset>(
        AudioQualityNotifier.new);

class AudioQualityNotifier extends AsyncNotifier<AudioQualityPreset> {
  @override
  Future<AudioQualityPreset> build() async {
    final val = await storage_api.loadSetting(key: 'audio_quality');
    return AudioQualityPreset.values.firstWhere(
      (p) => p.name == val,
      orElse: () => AudioQualityPreset.voice,
    );
  }

  Future<void> setPreset(AudioQualityPreset preset) async {
    await storage_api.saveSetting(
      key: 'audio_quality',
      value: preset.name,
    );
    state = AsyncData(preset);
  }
}

/// Microphone input gain — the LINEAR multiplier applied post-APM by the
/// native capture processor. With voice enhancement ON it is the chain's
/// input trim (2.0x = "100%" = unity trim); with enhancement OFF it is the
/// legacy flat makeup gain. Ignored entirely while Dynamic mode auto-levels.
/// See [kMicGainDisplayUnit] for the % mapping.
final micGainProvider =
    AsyncNotifierProvider<MicGainNotifier, double>(MicGainNotifier.new);

/// Mic gain bounds (actual linear multiplier). The slider goes BOTH ways
/// around the default: down to 34% (0.68x — floor is non-zero so the slider
/// can't mute the mic) and up to 200% (4.0x — the limiter still prevents
/// clipping).
const double kMicGainMin = 0.68;
const double kMicGainMax = 4.0;

/// The gain the UI shows as "100%". Display % = round(gain /
/// kMicGainDisplayUnit * 100), so 0.68x→34%, 2.0x→100%, 4.0x→200%.
const double kMicGainDisplayUnit = 2.0;

/// Default gain: 50% (0.5x trim into the enhancement chain). Device-tested
/// 2026-07-02: unity trim overdrives the chain on decent mics ("insanity");
/// a good hot mic wanted 34%, so 50% is the sane manual starting point.
/// (Dynamic mode, the default, ignores this and auto-levels instead.)
const double kMicGainDefault = 1.0;

class MicGainNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    // v2 key: the 2026-07-02 rescale changed both the range and the meaning
    // (with voice enhancement the gain is an input TRIM around unity at
    // "100%"). Reading the old 'mic_gain' key would pin pre-rescale users at
    // its old clamp floor ("stuck at 50%"), so everyone restarts at the
    // 100% default instead.
    final val = await storage_api.loadSetting(key: 'mic_gain_v2');
    if (val == null || val.isEmpty) return kMicGainDefault;
    return (double.tryParse(val) ?? kMicGainDefault)
        .clamp(kMicGainMin, kMicGainMax);
  }

  Future<void> setGain(double gain) async {
    final clamped = gain.clamp(kMicGainMin, kMicGainMax);
    await storage_api.saveSetting(
      key: 'mic_gain_v2',
      value: clamped.toStringAsFixed(2),
    );
    state = AsyncData(clamped);
  }
}

/// Received screen-share audio volume, in UI percent (0–200). Playback gain
/// is percent/200: 100% = the −6 dB calibration that sits mastered content
/// just under the voice chain's −16 LUFS target, 200% = the source's
/// original loudness (never amplified past unity, so it can't clip).
/// Applied by [ShareAudioLevel] together with voice-activity ducking.
const double kShareAudioVolumeDefault = 100.0;

final shareAudioVolumeProvider =
    AsyncNotifierProvider<ShareAudioVolumeNotifier, double>(
        ShareAudioVolumeNotifier.new);

class ShareAudioVolumeNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'share_audio_volume');
    if (val == null || val.isEmpty) return kShareAudioVolumeDefault;
    return (double.tryParse(val) ?? kShareAudioVolumeDefault)
        .clamp(0.0, 200.0);
  }

  Future<void> setVolume(double percent) async {
    final clamped = percent.clamp(0.0, 200.0).toDouble();
    await storage_api.saveSetting(
      key: 'share_audio_volume',
      value: clamped.toStringAsFixed(0),
    );
    state = AsyncData(clamped);
  }
}

/// Duck received screen-share audio by −10 dB while anyone in the call is
/// speaking (MV6-style sidechain off the existing VAD). Default ON — this is
/// what keeps voices on top of shared music without burying the share.
final shareAudioDuckProvider =
    AsyncNotifierProvider<ShareAudioDuckNotifier, bool>(
        ShareAudioDuckNotifier.new);

class ShareAudioDuckNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final val = await storage_api.loadSetting(key: 'share_audio_duck');
    if (val == null || val.isEmpty) return true;
    return val != 'false';
  }

  Future<void> setEnabled(bool enabled) async {
    await storage_api.saveSetting(
      key: 'share_audio_duck',
      value: enabled ? 'true' : 'false',
    );
    state = AsyncData(enabled);
  }
}

/// Voice enhancement — the native EQ + compressor + limiter chain applied to
/// the mic AFTER WebRTC's AGC (highpass + presence EQ, -18 dBFS 3:1
/// compressor with makeup, -1 dBFS limiter). Default ON: this is what makes
/// any mic land at a consistent, full loudness with zero setup. OFF falls
/// back to the flat makeup-gain + limiter path. All parameters are static —
/// the toggle exists so the two paths can be A/B'd live mid-call.
final voiceEnhanceProvider =
    AsyncNotifierProvider<VoiceEnhanceNotifier, bool>(VoiceEnhanceNotifier.new);

class VoiceEnhanceNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final val = await storage_api.loadSetting(key: 'voice_enhance');
    if (val == null || val.isEmpty) return true;
    return val != 'false';
  }

  Future<void> setEnabled(bool enabled) async {
    await storage_api.saveSetting(
      key: 'voice_enhance',
      value: enabled ? 'true' : 'false',
    );
    state = AsyncData(enabled);
  }
}

/// Voice-enhancement strength, in UI percent. Drives the chain's compressor
/// makeup gain live: 100% = +12 dB, 0% = no loudness boost (EQ + compression
/// still apply), 150% = +18 dB (the -1 dBFS limiter still caps peaks).
/// Default 30% (+3.6 dB) — the device-tested golden clarity setting.
const double kEnhanceStrengthMin = 0.0;
const double kEnhanceStrengthMax = 150.0;
const double kEnhanceStrengthDefault = 30.0;

/// The makeup gain (dB) the native chain applies at 100% strength.
const double kEnhanceMakeupDbAt100 = 12.0;

/// Maps the strength percent to the native chain's makeup gain in dB.
double enhanceStrengthToMakeupDb(double percent) =>
    kEnhanceMakeupDbAt100 * percent / 100.0;

final voiceEnhanceStrengthProvider =
    AsyncNotifierProvider<VoiceEnhanceStrengthNotifier, double>(
        VoiceEnhanceStrengthNotifier.new);

class VoiceEnhanceStrengthNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'voice_enhance_strength');
    if (val == null || val.isEmpty) return kEnhanceStrengthDefault;
    return (double.tryParse(val) ?? kEnhanceStrengthDefault)
        .clamp(kEnhanceStrengthMin, kEnhanceStrengthMax);
  }

  Future<void> setStrength(double percent) async {
    final clamped = percent.clamp(kEnhanceStrengthMin, kEnhanceStrengthMax);
    await storage_api.saveSetting(
      key: 'voice_enhance_strength',
      value: clamped.toStringAsFixed(0),
    );
    state = AsyncData(clamped);
  }
}

/// Dynamic mode — the "always sounds good" auto-level. A slow speech-gated
/// RMS meter in the native chain servos the input trim so ANY mic converges
/// to the calibrated speech level (the setting that sounded right on real
/// hardware), with the golden 30% strength. Locks the manual gain/strength
/// sliders while active. Default ON.
final voiceEnhanceDynamicProvider =
    AsyncNotifierProvider<VoiceEnhanceDynamicNotifier, bool>(
        VoiceEnhanceDynamicNotifier.new);

class VoiceEnhanceDynamicNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final val = await storage_api.loadSetting(key: 'voice_enhance_dynamic');
    if (val == null || val.isEmpty) return true;
    return val != 'false';
  }

  Future<void> setEnabled(bool enabled) async {
    await storage_api.saveSetting(
      key: 'voice_enhance_dynamic',
      value: enabled ? 'true' : 'false',
    );
    state = AsyncData(enabled);
  }
}

/// AI noise suppression — removes keyboard/fan/music/room noise from the
/// outgoing mic at the HEAD of the capture chain (post-AEC, the Krisp
/// slot). Independent of the Voice Enhancement toggle. While ON, WebRTC's
/// legacy NS is disabled in the capture constraints (double suppression =
/// artifacts); the services fall back to WebRTC NS automatically when the
/// engine can't run on this device. Default OFF while the feature matures
/// (flip after field validation). The engine is picked by
/// [noiseSuppressEngineProvider].
final noiseSuppressAiProvider =
    AsyncNotifierProvider<NoiseSuppressAiNotifier, bool>(
        NoiseSuppressAiNotifier.new);

class NoiseSuppressAiNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final val = await storage_api.loadSetting(key: 'noise_suppress_ai');
    if (val == null || val.isEmpty) return false;
    return val == 'true';
  }

  Future<void> setEnabled(bool enabled) async {
    await storage_api.saveSetting(
      key: 'noise_suppress_ai',
      value: enabled ? 'true' : 'false',
    );
    state = AsyncData(enabled);
  }
}

/// AI noise-suppression engine ('rnnoise' | 'dfn3'). RNNoise is the default
/// everywhere (instant init, ~1 MB, trivial CPU — the engine that actually
/// runs on every device); DeepFilterNet3 stays available behind the
/// advanced selector on desktop (higher suppression quality, 0.5 s desktop
/// / ~15 s mobile model load, ~10x the CPU). Switching while a call is live
/// swaps the engine in place — no re-capture, no renegotiation.
const kNoiseSuppressEngineRnnoise = 'rnnoise';
const kNoiseSuppressEngineDfn3 = 'dfn3';

/// Maps the persisted engine pref onto the native engine id
/// (Helper.nsEngineRnnoise / Helper.nsEngineDfn3 in the fork).
int noiseSuppressEngineToNative(String engine) =>
    engine == kNoiseSuppressEngineDfn3 ? 1 : 0;

final noiseSuppressEngineProvider =
    AsyncNotifierProvider<NoiseSuppressEngineNotifier, String>(
        NoiseSuppressEngineNotifier.new);

class NoiseSuppressEngineNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final val = await storage_api.loadSetting(key: 'noise_suppress_engine');
    if (val == kNoiseSuppressEngineDfn3) return kNoiseSuppressEngineDfn3;
    return kNoiseSuppressEngineRnnoise;
  }

  Future<void> setEngine(String engine) async {
    await storage_api.saveSetting(
      key: 'noise_suppress_engine',
      value: engine,
    );
    state = AsyncData(engine);
  }
}

/// Custom ringtone file path for incoming calls. Null = default system sound.
final ringtonePathProvider =
    AsyncNotifierProvider<RingtonePathNotifier, String?>(
        RingtonePathNotifier.new);

class RingtonePathNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    final val = await storage_api.loadSetting(key: 'ringtone_path');
    return (val == null || val.isEmpty) ? null : val;
  }

  Future<void> setPath(String? path) async {
    await storage_api.saveSetting(
      key: 'ringtone_path',
      value: path ?? '',
    );
    state = AsyncData(path);
  }
}

/// Cached ringtone duration in seconds. Avoids re-probing the file each
/// time the trim dialog opens. Updated when a new file is selected.
final ringtoneDurationProvider =
    AsyncNotifierProvider<RingtoneDurationNotifier, double>(
        RingtoneDurationNotifier.new);

class RingtoneDurationNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'ringtone_duration');
    if (val == null || val.isEmpty) return 0;
    return double.tryParse(val) ?? 0;
  }

  Future<void> setDuration(double seconds) async {
    await storage_api.saveSetting(
      key: 'ringtone_duration',
      value: seconds.toStringAsFixed(1),
    );
    state = AsyncData(seconds);
  }
}

/// Ringtone volume (0.0 to 1.0). Default: 0.5.
final ringtoneVolumeProvider =
    AsyncNotifierProvider<RingtoneVolumeNotifier, double>(
        RingtoneVolumeNotifier.new);

class RingtoneVolumeNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'ringtone_volume');
    final volume =
        (val == null || val.isEmpty) ? 0.5 : (double.tryParse(val) ?? 0.5);
    // The outgoing-call ringback plays from SoundService (no ref there).
    SoundService.ringtoneVolume = volume;
    return volume;
  }

  Future<void> setVolume(double volume) async {
    SoundService.ringtoneVolume = volume;
    await storage_api.saveSetting(
      key: 'ringtone_volume',
      value: volume.toStringAsFixed(2),
    );
    state = AsyncData(volume);
  }
}

/// Ringtone clip start offset in seconds. Default: 0.
final ringtoneStartProvider =
    AsyncNotifierProvider<RingtoneStartNotifier, double>(
        RingtoneStartNotifier.new);

class RingtoneStartNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'ringtone_start');
    if (val == null || val.isEmpty) return 0.0;
    return double.tryParse(val) ?? 0.0;
  }

  Future<void> setStart(double seconds) async {
    await storage_api.saveSetting(
      key: 'ringtone_start',
      value: seconds.toStringAsFixed(1),
    );
    state = AsyncData(seconds);
  }
}

/// Ringtone clip end offset in seconds. Default: 30 (or song duration if shorter).
final ringtoneEndProvider =
    AsyncNotifierProvider<RingtoneEndNotifier, double>(
        RingtoneEndNotifier.new);

class RingtoneEndNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'ringtone_end');
    if (val == null || val.isEmpty) return 30.0;
    return double.tryParse(val) ?? 30.0;
  }

  Future<void> setEnd(double seconds) async {
    await storage_api.saveSetting(
      key: 'ringtone_end',
      value: seconds.toStringAsFixed(1),
    );
    state = AsyncData(seconds);
  }
}

/// Auto-download threshold in MB. Gates share-backed auto-starts (Dart) AND
/// pushed/pulled regular files (pushed to Rust via setAutoDownloadConfig).
/// 0 = automatic downloads OFF (issue #41); otherwise 34–2048. Default: 169 MB.
final autoDownloadThresholdProvider =
    AsyncNotifierProvider<AutoDownloadThresholdNotifier, int>(
        AutoDownloadThresholdNotifier.new);

class AutoDownloadThresholdNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final val = await storage_api.loadSetting(key: 'auto_download_threshold_mb');
    if (val != null && val.isNotEmpty) {
      final mb = int.tryParse(val);
      if (mb != null && (mb == 0 || mb >= 34)) return mb;
    }
    return 169;
  }

  Future<void> setThreshold(int mb) async {
    final clamped = mb <= 0 ? 0 : mb.clamp(34, 2048);
    await storage_api.saveSetting(
      key: 'auto_download_threshold_mb',
      value: clamped.toString(),
    );
    state = AsyncData(clamped);
    final overrides = await ref
        .read(autoDownloadOverridesProvider.future)
        .catchError((_) => const <String, bool>{});
    await pushAutoDownloadConfig(thresholdMb: clamped, overrides: overrides);
  }
}

/// Per-conversation auto-download overrides (issue #41). Keys are
/// `dm:{master}` / `server:{server_id}`; `false` = never auto-download there,
/// `true` = auto-download there even when the global threshold is 0 (Off).
/// Absent = follow the global setting. Persisted as one JSON object.
final autoDownloadOverridesProvider =
    AsyncNotifierProvider<AutoDownloadOverridesNotifier, Map<String, bool>>(
        AutoDownloadOverridesNotifier.new);

class AutoDownloadOverridesNotifier extends AsyncNotifier<Map<String, bool>> {
  @override
  Future<Map<String, bool>> build() async {
    final val = await storage_api.loadSetting(key: 'auto_download_overrides');
    if (val == null || val.isEmpty) return const {};
    try {
      final decoded = jsonDecode(val) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v == true));
    } catch (_) {
      return const {};
    }
  }

  /// `null` removes the override (follow the global setting).
  Future<void> setOverride(String contextKey, bool? autoDownload) async {
    final current = Map<String, bool>.from(state.valueOrNull ?? const {});
    if (autoDownload == null) {
      current.remove(contextKey);
    } else {
      current[contextKey] = autoDownload;
    }
    await storage_api.saveSetting(
      key: 'auto_download_overrides',
      value: jsonEncode(current),
    );
    state = AsyncData(current);
    final threshold = await ref
        .read(autoDownloadThresholdProvider.future)
        .catchError((_) => 169);
    await pushAutoDownloadConfig(thresholdMb: threshold, overrides: current);
  }
}

/// Push the combined auto-download config into Rust. Called from _bootstrap
/// (explicitly — never rely on a lazy provider build reaching Rust, same rule
/// as setRelayUrl) and after every threshold/override change.
Future<void> pushAutoDownloadConfig({
  required int thresholdMb,
  required Map<String, bool> overrides,
}) async {
  await network_api
      .setAutoDownloadConfig(
        thresholdMb: thresholdMb,
        overridesJson: jsonEncode(overrides),
      )
      .catchError((_) {});
}

/// Effective auto-download threshold in MB for one conversation
/// (`dm:{master}` / `server:{server_id}`). 0 = off. Mirrors the Rust-side
/// `effective_auto_download_mb` — keep the two in sync.
int effectiveAutoDownloadMb(WidgetRef ref, String contextKey) =>
    _effectiveAutoDownloadMb(
      ref.watch(autoDownloadThresholdProvider).valueOrNull ?? 169,
      ref.watch(autoDownloadOverridesProvider).valueOrNull ?? const {},
      contextKey,
    );

/// Read-only variant for providers/notifiers holding a [Ref].
int effectiveAutoDownloadMbRead(Ref ref, String contextKey) =>
    _effectiveAutoDownloadMb(
      ref.read(autoDownloadThresholdProvider).valueOrNull ?? 169,
      ref.read(autoDownloadOverridesProvider).valueOrNull ?? const {},
      contextKey,
    );

int _effectiveAutoDownloadMb(
    int global, Map<String, bool> overrides, String contextKey) {
  final override = overrides[contextKey];
  if (override == false) return 0;
  if (override == true) return global == 0 ? 169 : global;
  return global;
}

/// True when [fileName] is a recorded voice message. Voice notes are exempt
/// from the auto-download gate on every path (they behave like text). Matches
/// both the UI display name and the recorder's temp basename that actually
/// rides the wire (`voice_{stamp}_{rand}.ogg`) — keep in sync with the Rust
/// twin `file_handler::is_voice_message_name`.
bool isVoiceMessageFile(String fileName) {
  return fileName == 'Voice message.ogg' ||
      (fileName.startsWith('voice_') && fileName.endsWith('.ogg'));
}

/// Vault cache size cap in MB. Files downloaded from server channels are
/// LRU-evicted when the cache exceeds this limit. Default: 1024 MB (1 GB).
final vaultCacheCapProvider =
    AsyncNotifierProvider<VaultCacheCapNotifier, int>(
        VaultCacheCapNotifier.new);

class VaultCacheCapNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final val = await storage_api.loadSetting(key: 'vault_cache_cap_mb');
    if (val != null && val.isNotEmpty) {
      final mb = int.tryParse(val);
      if (mb != null && mb >= 256) return mb;
    }
    return 1024;
  }

  Future<void> setCap(int mb) async {
    final clamped = mb.clamp(256, 10240);
    await storage_api.saveSetting(
      key: 'vault_cache_cap_mb',
      value: clamped.toString(),
    );
    state = AsyncData(clamped);
  }
}

/// Downloaded-files cache size cap in MB. Files downloaded in DMs/channels live
/// in `~/hollow/files/`; oldest bytes are LRU-evicted when the directory exceeds
/// this limit (signed headers are kept, so messages stay re-downloadable).
/// Default: 5120 MB (5 GB). Surfaced + enforced by the Storage Manager.
final filesCacheCapProvider =
    AsyncNotifierProvider<FilesCacheCapNotifier, int>(
        FilesCacheCapNotifier.new);

class FilesCacheCapNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final val = await storage_api.loadSetting(key: 'files_cache_cap_mb');
    if (val != null && val.isNotEmpty) {
      final mb = int.tryParse(val);
      if (mb != null && mb >= 512) return mb;
    }
    return 5120;
  }

  Future<void> setCap(int mb) async {
    final clamped = mb.clamp(512, 51200);
    await storage_api.saveSetting(
      key: 'files_cache_cap_mb',
      value: clamped.toString(),
    );
    state = AsyncData(clamped);
  }
}

/// Asset blob cache cap in MB (emotes, stickers, GIFs, banners — the
/// content-addressed blobs inside the encrypted DB). LRU-evicted past the
/// cap; hashes still referenced by a personal set or a server's CRDT state
/// are never evicted. Default: 512 MB.
final assetCacheCapProvider =
    AsyncNotifierProvider<AssetCacheCapNotifier, int>(
        AssetCacheCapNotifier.new);

class AssetCacheCapNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final val = await storage_api.loadSetting(key: 'asset_cache_cap_mb');
    if (val != null && val.isNotEmpty) {
      final mb = int.tryParse(val);
      if (mb != null && mb >= 64) return mb;
    }
    return 512;
  }

  Future<void> setCap(int mb) async {
    final clamped = mb.clamp(64, 4096);
    await storage_api.saveSetting(
      key: 'asset_cache_cap_mb',
      value: clamped.toString(),
    );
    state = AsyncData(clamped);
  }
}

// ── Official REALITY tunnel defaults (Hollow's shared Xray on the VPS) ────────
// Baked in like `kDefaultRelayDomain` so a normal user just flips the toggle —
// no copy-paste. The fields stay editable for anyone self-hosting their own
// relay + Xray. Update these if the server's keys/SNI are rotated.
const kDefaultProxyServer = '141.227.186.209:443';
const kDefaultProxyUuid = 'bfe68ae0-4435-41ec-950a-aacc1caa2771';
const kDefaultProxyPublicKey = 'zWJevNXCtw-PMBsUrrJWmYNZlXeSP5ojVDH8aoCA_xQ';
const kDefaultProxyShortId = '5294730d0b4e9be7';
const kDefaultProxySni = 'www.microsoft.com';

/// Anti-censorship proxy (VLESS+REALITY tunnel via the bundled `shoes` client).
/// For users behind DPI censorship (Russia/TSPU, China/GFW): routes the relay
/// WSS connection through a local REALITY tunnel that looks like ordinary HTTPS.
/// Pre-filled with the official Hollow config (above); editable for self-hosters.
/// Changes take effect on the NEXT node start (toggling requires a restart, like
/// the relay domain) — pushed to Rust via `setProxyConfig` before start_node.
@immutable
class ProxyConfig {
  final bool enabled;
  final String server; // host:port, e.g. 141.227.186.209:8443
  final String uuid;
  final String publicKey; // REALITY public key (Xray prints as "Password")
  final String shortId;
  final String sni; // serverName to clone, e.g. www.microsoft.com

  const ProxyConfig({
    this.enabled = false,
    this.server = kDefaultProxyServer,
    this.uuid = kDefaultProxyUuid,
    this.publicKey = kDefaultProxyPublicKey,
    this.shortId = kDefaultProxyShortId,
    this.sni = kDefaultProxySni,
  });

  /// True when every required field is present (shortId may be empty).
  bool get isComplete =>
      server.trim().isNotEmpty &&
      uuid.trim().isNotEmpty &&
      publicKey.trim().isNotEmpty &&
      sni.trim().isNotEmpty;

  /// The proxy is only actually active when enabled AND fully configured.
  bool get isActive => enabled && isComplete;

  ProxyConfig copyWith({
    bool? enabled,
    String? server,
    String? uuid,
    String? publicKey,
    String? shortId,
    String? sni,
  }) => ProxyConfig(
        enabled: enabled ?? this.enabled,
        server: server ?? this.server,
        uuid: uuid ?? this.uuid,
        publicKey: publicKey ?? this.publicKey,
        shortId: shortId ?? this.shortId,
        sni: sni ?? this.sni,
      );
}

/// Loaded from the local DB at startup, persisted per-field, pushed to Rust.
final proxyConfigProvider =
    AsyncNotifierProvider<ProxyConfigNotifier, ProxyConfig>(
        ProxyConfigNotifier.new);

class ProxyConfigNotifier extends AsyncNotifier<ProxyConfig> {
  @override
  Future<ProxyConfig> build() async {
    // Absent DB key (fresh install) → fall back to the baked-in official config
    // so the fields are pre-filled and the toggle "just works". A present value
    // (even empty — a self-hoster who cleared a field) is respected as-is.
    final cfg = ProxyConfig(
      enabled: (await storage_api.loadSetting(key: 'proxy_enabled')) == 'true',
      server:
          (await storage_api.loadSetting(key: 'proxy_server')) ?? kDefaultProxyServer,
      uuid: (await storage_api.loadSetting(key: 'proxy_uuid')) ?? kDefaultProxyUuid,
      publicKey: (await storage_api.loadSetting(key: 'proxy_public_key')) ??
          kDefaultProxyPublicKey,
      shortId: (await storage_api.loadSetting(key: 'proxy_short_id')) ??
          kDefaultProxyShortId,
      sni: (await storage_api.loadSetting(key: 'proxy_sni')) ?? kDefaultProxySni,
    );
    // Push the persisted config into Rust so a launch with proxy pre-enabled
    // brings the tunnel up. Safe pre-node-start (seeds a global). Best-effort.
    await _push(cfg);
    return cfg;
  }

  Future<void> _push(ProxyConfig cfg) async {
    try {
      await network_api.setProxyConfig(
        enabled: cfg.enabled,
        server: cfg.server.trim(),
        uuid: cfg.uuid.trim(),
        publicKey: cfg.publicKey.trim(),
        shortId: cfg.shortId.trim(),
        sni: cfg.sni.trim(),
      );
    } catch (_) {}
  }

  /// Update the whole config (persist every field + push to Rust). Takes effect
  /// on the next node restart.
  Future<void> save(ProxyConfig cfg) async {
    await storage_api.saveSetting(
        key: 'proxy_enabled', value: cfg.enabled.toString());
    await storage_api.saveSetting(key: 'proxy_server', value: cfg.server.trim());
    await storage_api.saveSetting(key: 'proxy_uuid', value: cfg.uuid.trim());
    await storage_api.saveSetting(
        key: 'proxy_public_key', value: cfg.publicKey.trim());
    await storage_api.saveSetting(
        key: 'proxy_short_id', value: cfg.shortId.trim());
    await storage_api.saveSetting(key: 'proxy_sni', value: cfg.sni.trim());
    await _push(cfg);
    state = AsyncData(cfg);
  }

  /// Toggle just the enabled flag, keeping the entered config.
  Future<void> setEnabled(bool value) async {
    final current = state.valueOrNull ?? const ProxyConfig();
    await save(current.copyWith(enabled: value));
  }
}

/// Whether the user wants to appear invisible (offline) to others.
/// Synchronous state — loaded eagerly during bootstrap, persisted on toggle.
class InvisibleModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Load persisted value from DB. Called during bootstrap (fire-and-forget).
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'invisible_mode');
      debugPrint('[HOLLOW] invisibleMode.load() → raw="$val" → ${val == "true"}');
      state = val == 'true';
    } catch (e) {
      debugPrint('[HOLLOW] invisibleMode.load() failed: $e');
    }
  }

  Future<void> setInvisible(bool value) async {
    debugPrint('[HOLLOW] invisibleMode.setInvisible($value)');
    state = value;
    await storage_api.saveSetting(
      key: 'invisible_mode',
      value: value.toString(),
    );
    try {
      await network_api.setInvisible(invisible: value);
    } catch (_) {}
  }
}

final invisibleModeProvider =
    NotifierProvider<InvisibleModeNotifier, bool>(InvisibleModeNotifier.new);

/// "Always relay calls" — force every real-time peer connection through the
/// TURN relay so co-participants never learn this device's IP address.
///
/// On a direct (host / server-reflexive) ICE path both sides see each other's
/// addresses; DTLS + SFrame protect content, not network addresses. Turning
/// this on makes [IceConfigNotifier] emit `iceTransportPolicy: 'relay'`, so
/// only relay candidates are gathered.
///
/// Default OFF — direct paths are the whole point of P2P, and forcing every
/// call onto the relay costs latency, quality and relay bandwidth. Same
/// default Signal ships for its equivalent setting.
///
/// Synchronous state — loaded eagerly during bootstrap, persisted on toggle.
class AlwaysRelayCallsNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Load persisted value from DB. Called during bootstrap, BEFORE the node
  /// starts — a peer connection built before this lands would use the wrong
  /// policy.
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'always_relay_calls');
      state = val == 'true';
    } catch (e) {
      debugPrint('[HOLLOW] alwaysRelayCalls.load() failed: $e');
    }
  }

  /// Persist the flag. Deliberately does NOT swallow a save failure — call
  /// sites await and toast, so a silently-unsaved privacy setting can't happen.
  Future<void> setEnabled(bool value) async {
    state = value;
    await storage_api.saveSetting(
      key: 'always_relay_calls',
      value: value.toString(),
    );
  }
}

final alwaysRelayCallsProvider =
    NotifierProvider<AlwaysRelayCallsNotifier, bool>(
        AlwaysRelayCallsNotifier.new);

/// UI sound effects — join/leave voice, screen share start/stop, mute/deafen/
/// camera, message notification (issue #55). Default ON.
///
/// Synchronous state loaded from bootstrap, and mirrored into [SoundService]'s
/// statics on every change: the sounds fire from inside notifiers (including
/// teardown paths) where re-entering the provider container is not safe.
class SoundEffectsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'sound_effects_enabled');
      // Absent key = first run = enabled; only an explicit 'false' turns it off.
      state = val != 'false';
    } catch (e) {
      debugPrint('[HOLLOW] soundEffectsEnabled.load() failed: $e');
    }
    SoundService.enabled = state;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    SoundService.enabled = value;
    await storage_api.saveSetting(
      key: 'sound_effects_enabled',
      value: value.toString(),
    );
  }
}

final soundEffectsEnabledProvider =
    NotifierProvider<SoundEffectsEnabledNotifier, bool>(
        SoundEffectsEnabledNotifier.new);

/// UI sound effects volume (0.0–1.0). Default 0.5 — same as the ringtone.
class SoundEffectsVolumeNotifier extends Notifier<double> {
  @override
  double build() => 0.5;

  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'sound_effects_volume');
      if (val != null && val.isNotEmpty) {
        state = (double.tryParse(val) ?? 0.5).clamp(0.0, 1.0);
      }
    } catch (e) {
      debugPrint('[HOLLOW] soundEffectsVolume.load() failed: $e');
    }
    SoundService.volume = state;
  }

  Future<void> setVolume(double value) async {
    final v = value.clamp(0.0, 1.0);
    state = v;
    SoundService.volume = v;
    await storage_api.saveSetting(
      key: 'sound_effects_volume',
      value: v.toStringAsFixed(2),
    );
  }
}

final soundEffectsVolumeProvider =
    NotifierProvider<SoundEffectsVolumeNotifier, double>(
        SoundEffectsVolumeNotifier.new);

/// Description shown under the "Always relay calls" toggle on desktop AND
/// mobile — one source of truth so the two can't drift.
///
/// The Hollow Share sentence is NOT optional: Share deliberately stays
/// peer-to-peer even with this on (HOLLOW_PLAN §7A), and a privacy switch with
/// an undisclosed carve-out is exactly the kind of overclaim worth avoiding.
const String alwaysRelayCallsDescription =
    'Routes calls, video, screen share and file transfers through the relay so '
    'other participants never see your IP address. May reduce quality and '
    'increase latency. Restart is required.';

/// Peer media forwarding (media forwarding step 3 phase 2): this desktop may
/// serve as a blind packet forwarder for screen shares it watches, carrying
/// the stream to viewers who can't connect directly — the collective-hosting
/// principle applied to live media. ON by default (Vitalik decision
/// 2026-08-06); desktop only, never mobile. The forwarder relays SFrame
/// CIPHERTEXT it can already decrypt as a watcher — serving costs upload
/// bandwidth (up to 3 extra stream copies), never privacy.
///
/// Synchronous state — loaded eagerly during bootstrap, pushed to Rust
/// (`set_peer_forwarding_enabled`) after the node starts and on every toggle.
class PeerForwardingNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  /// Load persisted value from DB. Default-ON: only an explicit 'false'
  /// disables (absent key = first run = enabled).
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'peer_media_forwarding');
      state = val != 'false';
    } catch (e) {
      debugPrint('[HOLLOW] peerForwarding.load() failed: $e');
    }
  }

  /// Push the current value into the node (call after node start, and after
  /// [load] — the Rust side defaults to disabled until told).
  Future<void> pushToNode() async {
    try {
      await network_api.setPeerForwardingEnabled(enabled: state);
    } catch (e) {
      debugPrint('[HOLLOW] peerForwarding.pushToNode() failed: $e');
    }
  }

  /// Persist + push. Does NOT swallow the save failure — call sites await
  /// and toast. Disabling mid-serve tears active forwarding down (downstream
  /// viewers heal to another path automatically).
  Future<void> setEnabled(bool value) async {
    state = value;
    await storage_api.saveSetting(
      key: 'peer_media_forwarding',
      value: value.toString(),
    );
    await pushToNode();
  }
}

final peerForwardingProvider = NotifierProvider<PeerForwardingNotifier, bool>(
    PeerForwardingNotifier.new);

/// Description under the "Peer media forwarding" toggle (desktop settings).
const String peerForwardingDescription =
    'While you watch a screen share, help carry it to viewers who can\'t '
    'connect directly, instead of routing them through the relay server. '
    'Streams stay end-to-end encrypted; helping costs some upload bandwidth. '
    'Desktop only.';

/// Offline inbox retention window in DAYS (1 / 3 / 7). Only meaningful while
/// [offlineInboxProvider] is enabled; the relay clamps server-side too.
class OfflineInboxRetentionNotifier extends Notifier<int> {
  @override
  int build() => 3;

  /// Load persisted value from DB. Called during bootstrap BEFORE
  /// [OfflineInboxNotifier.load] so the enable re-apply reads the right days.
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'offline_inbox_retention_days');
      final days = int.tryParse(val ?? '') ?? 0;
      if (days == 1 || days == 3 || days == 7) state = days;
    } catch (_) {}
  }

  Future<void> setDays(int days) async {
    if (days != 1 && days != 3 && days != 7) return;
    state = days;
    await storage_api.saveSetting(
      key: 'offline_inbox_retention_days',
      value: days.toString(),
    );
    // Re-register with the relay if the feature is on.
    if (ref.read(offlineInboxProvider)) {
      try {
        await network_api.setOfflineInbox(
          enabled: true,
          retentionSecs: days * 86400,
        );
      } catch (_) {}
    }
  }
}

final offlineInboxRetentionProvider =
    NotifierProvider<OfflineInboxRetentionNotifier, int>(
        OfflineInboxRetentionNotifier.new);

/// Offline inbox ("offline message delivery") — ON by default at 3 days
/// (2026-07-04: users won't discover the toggle and will assume offline
/// delivery is broken; turning it off is the explicit choice). While enabled,
/// the relay keeps encrypted DM text + file cards addressed to this device for
/// the chosen retention (instead of the 24h push baseline) and replays them on
/// the next connect, deleting delivered entries. Text and file metadata only —
/// never file bytes; content stays E2EE (the relay holds ciphertext it cannot
/// read or forge). The relay registry is RAM-only, so the FFI is re-applied on
/// every app start; Rust's ws_client then re-registers on every reconnect.
class OfflineInboxNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  /// Load persisted value + re-register with the relay. Called during
  /// bootstrap (fire-and-forget), after the node has started. Never-touched
  /// setting = default ON.
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'offline_inbox_enabled');
      if (val != null && val.isNotEmpty) state = val == 'true';
      if (state) await _apply();
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await storage_api.saveSetting(
      key: 'offline_inbox_enabled',
      value: value.toString(),
    );
    await _apply();
  }

  Future<void> _apply() async {
    final days = ref.read(offlineInboxRetentionProvider);
    try {
      await network_api.setOfflineInbox(
        enabled: state,
        retentionSecs: days * 86400,
      );
    } catch (_) {} // node not running yet — bootstrap re-applies after start
  }
}

final offlineInboxProvider =
    NotifierProvider<OfflineInboxNotifier, bool>(OfflineInboxNotifier.new);

// ---------------------------------------------------------------------------
// Voice input mode + hotkeys (issue #38)
// ---------------------------------------------------------------------------

/// Voice input mode values for [voiceInputModeProvider].
const String kVoiceInputActivity = 'activity';
const String kVoiceInputPtt = 'ptt';

/// How the mic transmits in calls: 'activity' (always-on, default) or 'ptt'
/// (push-to-talk — mic only transmits while the PTT key is held).
final voiceInputModeProvider =
    AsyncNotifierProvider<VoiceInputModeNotifier, String>(
        VoiceInputModeNotifier.new);

class VoiceInputModeNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final val = await storage_api.loadSetting(key: 'voice_input_mode');
    return val == kVoiceInputPtt ? kVoiceInputPtt : kVoiceInputActivity;
  }

  Future<void> setMode(String mode) async {
    final v = mode == kVoiceInputPtt ? kVoiceInputPtt : kVoiceInputActivity;
    await storage_api.saveSetting(key: 'voice_input_mode', value: v);
    state = AsyncData(v);
  }
}

/// Push-to-talk release delay in milliseconds — how long the mic stays open
/// after the key is released, so word endings aren't clipped.
const int kPttReleaseDefaultMs = 200;

final pttReleaseDelayProvider =
    AsyncNotifierProvider<PttReleaseDelayNotifier, int>(
        PttReleaseDelayNotifier.new);

class PttReleaseDelayNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final val = await storage_api.loadSetting(key: 'ptt_release_ms');
    if (val == null || val.isEmpty) return kPttReleaseDefaultMs;
    return (int.tryParse(val) ?? kPttReleaseDefaultMs).clamp(0, 1000);
  }

  Future<void> setDelay(int ms) async {
    final clamped = ms.clamp(0, 1000);
    await storage_api.saveSetting(
      key: 'ptt_release_ms',
      value: clamped.toString(),
    );
    state = AsyncData(clamped);
  }
}

/// Serialized [HotkeyBinding] strings (e.g. 'ctrl+space'); empty = unbound.
class KeybindNotifier extends AsyncNotifier<String> {
  final String storageKey;
  final String defaultBinding;
  KeybindNotifier(this.storageKey, this.defaultBinding);

  @override
  Future<String> build() async {
    final val = await storage_api.loadSetting(key: storageKey);
    if (val == null || val.isEmpty) return defaultBinding;
    return val;
  }

  Future<void> setBinding(String serialized) async {
    await storage_api.saveSetting(key: storageKey, value: serialized);
    state = AsyncData(serialized);
  }
}

/// Push-to-talk key (hold to transmit). Default Ctrl+Space.
final pttKeybindProvider = AsyncNotifierProvider<KeybindNotifier, String>(
    () => KeybindNotifier('ptt_keybind', 'ctrl+space'));

/// Mute-toggle hotkey. Default Ctrl+Shift+M (the member panel moved to
/// Ctrl+Shift+P to give the Discord muscle-memory combo to mute).
final muteKeybindProvider = AsyncNotifierProvider<KeybindNotifier, String>(
    () => KeybindNotifier('mute_keybind', 'ctrl+shift+m'));

/// Deafen-toggle hotkey. Default Ctrl+Shift+D.
final deafenKeybindProvider = AsyncNotifierProvider<KeybindNotifier, String>(
    () => KeybindNotifier('deafen_keybind', 'ctrl+shift+d'));

/// True while the settings keybind-capture field is armed — the hotkey
/// controller suspends so the capture never triggers live actions.
final keybindCaptureActiveProvider = StateProvider<bool>((_) => false);

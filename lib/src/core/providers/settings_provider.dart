import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/reduce_motion.dart';
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
  lossless('Lossless (100%)', 'Pixel-perfect — for art, diagrams, screenshots'),
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
  voice('Voice', 32000, false),     // 32 kbps mono — speech-optimized
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
    if (val == null || val.isEmpty) return 0.5;
    return double.tryParse(val) ?? 0.5;
  }

  Future<void> setVolume(double volume) async {
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

/// Auto-download threshold for share-backed files (in MB).
/// Files up to this size auto-download; larger ones require manual action.
/// Minimum: 34 MB (the share-backed file threshold). Default: 169 MB.
final autoDownloadThresholdProvider =
    AsyncNotifierProvider<AutoDownloadThresholdNotifier, int>(
        AutoDownloadThresholdNotifier.new);

class AutoDownloadThresholdNotifier extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    final val = await storage_api.loadSetting(key: 'auto_download_threshold_mb');
    if (val != null && val.isNotEmpty) {
      final mb = int.tryParse(val);
      if (mb != null && mb >= 34) return mb;
    }
    return 169;
  }

  Future<void> setThreshold(int mb) async {
    final clamped = mb.clamp(34, 2048);
    await storage_api.saveSetting(
      key: 'auto_download_threshold_mb',
      value: clamped.toString(),
    );
    state = AsyncData(clamped);
  }
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

/// Whether the Shadowsocks proxy is enabled (for censored networks).
/// Loaded from the local DB at startup.
final proxyEnabledProvider =
    AsyncNotifierProvider<ProxyEnabledNotifier, bool>(ProxyEnabledNotifier.new);

class ProxyEnabledNotifier extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final val = await storage_api.loadSetting(key: 'proxy_enabled');
    return val == 'true';
  }

  Future<void> setEnabled(bool value) async {
    await storage_api.saveSetting(
      key: 'proxy_enabled',
      value: value.toString(),
    );
    state = AsyncData(value);
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

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

/// Microphone input gain — the LINEAR makeup multiplier applied post-APM by the
/// native capture-gain processor (then a -3 dBFS soft limiter caps peaks).
///
/// WebRTC's own AGC leaves the mic quiet (~-18 dBFS), so the DEFAULT is a 2.0x
/// boost: that's what makes calls land at a normal, audible loudness with no
/// user setup. The UI calls 2.0x "100%" (the standard/normalized level), with
/// room to go quieter (down to 1.0x = 50%) or louder (up to 3.0x = 150%). See
/// [kMicGainDisplayUnit] for the % mapping.
final micGainProvider =
    AsyncNotifierProvider<MicGainNotifier, double>(MicGainNotifier.new);

/// Mic gain bounds (actual linear multiplier). 1.0x is WebRTC's quiet baseline
/// (no boost); 3.0x is extra-hot (the -3 dB limiter still prevents clipping).
const double kMicGainMin = 1.0;
const double kMicGainMax = 3.0;

/// The actual gain that the UI shows as "100%" — the standard/normalized loud
/// level and the default. Display % = round(gain / kMicGainDisplayUnit * 100),
/// so 1.0x→50%, 2.0x→100%, 3.0x→150%.
const double kMicGainDisplayUnit = 2.0;

/// Default gain (== the "100%" / normalized level).
const double kMicGainDefault = kMicGainDisplayUnit;

class MicGainNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'mic_gain');
    if (val == null || val.isEmpty) return kMicGainDefault;
    return (double.tryParse(val) ?? kMicGainDefault)
        .clamp(kMicGainMin, kMicGainMax);
  }

  Future<void> setGain(double gain) async {
    final clamped = gain.clamp(kMicGainMin, kMicGainMax);
    await storage_api.saveSetting(
      key: 'mic_gain',
      value: clamped.toStringAsFixed(2),
    );
    state = AsyncData(clamped);
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

import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Microphone input gain (0.0 to 2.0). Default: 1.0 (no boost).
/// Values >1.0 boost, <1.0 reduce. Applied to the local audio track.
final micGainProvider =
    AsyncNotifierProvider<MicGainNotifier, double>(MicGainNotifier.new);

class MicGainNotifier extends AsyncNotifier<double> {
  @override
  Future<double> build() async {
    final val = await storage_api.loadSetting(key: 'mic_gain');
    if (val == null || val.isEmpty) return 1.0;
    return double.tryParse(val) ?? 1.0;
  }

  Future<void> setGain(double gain) async {
    await storage_api.saveSetting(
      key: 'mic_gain',
      value: gain.toStringAsFixed(2),
    );
    state = AsyncData(gain);
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

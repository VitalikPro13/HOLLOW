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

import 'dart:io' show Platform;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';

/// Why listening could not start.
class OverlayMicRefused implements Exception {
  final String message;
  const OverlayMicRefused(this.message);

  @override
  String toString() => message;
}

/// Whether this platform listens for the overlay at all: phones have no OBS
/// to point at the page. Swappable in tests.
bool Function() overlayMicSupported =
    () => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// "Listen to my mic now", for the UI. The ONE entry point that turns it on:
/// it refuses unless the overlay server runs and the app is unlocked, and it
/// turns listening off when the server stops, App Lock engages or the roster
/// locks this device.
final overlayMicProvider =
    NotifierProvider<OverlayMicNotifier, OverlayMicStatus>(
        OverlayMicNotifier.new);

/// Whether our own voice is over the threshold while listening.
final overlayMicSpeakingProvider =
    NotifierProvider<OverlayMicSpeakingNotifier, bool>(
        OverlayMicSpeakingNotifier.new);

class OverlayMicSpeakingNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool speaking) {
    if (state != speaking) state = speaking;
  }
}

class OverlayMicNotifier extends Notifier<OverlayMicStatus> {
  late OverlayMic _mic;

  @override
  OverlayMicStatus build() {
    final mic = overlayMic;
    _mic = mic;
    void onStatus() => state = mic.status.value;
    void onSpeaking() =>
        ref.read(overlayMicSpeakingProvider.notifier).set(mic.speaking.value);
    mic.status.addListener(onStatus);
    mic.speaking.addListener(onSpeaking);
    mic.onLevelDb =
        (db) => ref.read(listenLevelProvider.notifier).set(levelFromDb(db));
    mic.inputDevice = () async {
      final loaded = ref.read(audioInputDeviceProvider);
      if (!loaded.isLoading) return loaded.valueOrNull;
      try {
        return await ref
            .read(audioInputDeviceProvider.future)
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        return null;
      }
    };
    ref.onDispose(() {
      mic.status.removeListener(onStatus);
      mic.speaking.removeListener(onSpeaking);
      mic.onLevelDb = null;
      mic.inputDevice = null;
    });

    ref.listen<bool>(overlayServerRunningProvider, (_, running) {
      if (!running) _stop();
    });
    ref.listen<bool>(appLockedProvider, (_, locked) {
      if (locked) _stop();
    });
    ref.listen<RosterGate>(rosterGateProvider, (_, gate) {
      if (gate.kind != RosterGateKind.none) _stop();
    });
    return mic.status.value;
  }

  /// Starts listening. Throws [OverlayMicRefused] when it may not run, or the
  /// capture's error when the microphone would not open.
  Future<void> turnOn() async {
    if (!overlayMicSupported()) {
      throw const OverlayMicRefused('Listening works on desktop only.');
    }
    if (!ref.read(overlayServerRunningProvider)) {
      throw const OverlayMicRefused('Turn on the overlay for OBS first.');
    }
    if (ref.read(appLockedProvider) ||
        ref.read(rosterGateProvider).kind != RosterGateKind.none) {
      throw const OverlayMicRefused('Unlock Hollow first.');
    }
    await _mic.turnOn();
  }

  Future<void> turnOff() => _mic.turnOff();

  void setThresholdDb(double db) => _mic.thresholdDb = db;

  void setHold(Duration hold) => _mic.hold = hold;

  void _stop() {
    if (!_mic.status.value.on) return;
    _mic.turnOff().catchError((_) {});
  }
}

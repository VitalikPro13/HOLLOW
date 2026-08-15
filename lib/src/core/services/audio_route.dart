import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// Where a phone call's audio physically goes (and, on iOS, where its mic
/// comes from — the two travel together in an AVAudioSession route).
///
/// Deliberately a small closed set of ROUTES rather than a device list: a
/// phone has one earpiece, one loudspeaker and at most one attached headset,
/// and that is the vocabulary both platforms speak (Android audioswitch's
/// AudioDevice classes, iOS's port types).
enum AudioRouteKind {
  speaker,
  earpiece,
  wired,
  bluetooth,
  usb,
  carAudio,
  airplay,
}

extension AudioRouteKindX on AudioRouteKind {
  /// Headset-class routes: a device the user attached, which must always
  /// outrank the built-in loudspeaker.
  bool get isExternal =>
      this != AudioRouteKind.speaker && this != AudioRouteKind.earpiece;
}

@immutable
class AudioRoute {
  /// Platform selector. Android: an `AudioDeviceKind` type name. iOS: a port
  /// UID (or the literal `Speaker` for the loudspeaker override).
  final String id;
  final String label;
  final AudioRouteKind kind;

  /// iOS only: the UID of this route's INPUT port, when it has one. iOS
  /// cannot pick an output directly — you pin the input with
  /// `setPreferredInput:` and the output follows for headset-class routes.
  final String? inputUid;

  const AudioRoute({
    required this.id,
    required this.label,
    required this.kind,
    this.inputUid,
  });

  @override
  bool operator ==(Object other) =>
      other is AudioRoute && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);

  @override
  String toString() => 'AudioRoute($kind, $label, id=$id)';
}

/// Mobile call audio routing: enumerate the routes a call can run on, read
/// the one it is actually on, and switch between them.
///
/// **The rule this type exists to enforce: a connected headset always beats
/// the built-in loudspeaker.** Hollow defaults voice channels and video calls
/// to "speaker on", and on iOS that used to mean a hard
/// `overrideOutputAudioPort(.speaker)` — which OUTRANKS wired headphones, so
/// a user who joined with headphones in heard nothing (and iOS moved capture
/// to the built-in mic along with it). [preferLoudRoute] is the corrected
/// meaning of "speaker on": the loudest sensible route, which is the headset
/// whenever one is attached.
class AudioRoutes {
  const AudioRoutes._();

  /// Test seam. Host tests run on neither Android nor iOS, but the routing
  /// RULES here are platform-independent and are exactly what regressed —
  /// so they get pinned down (`test/audio_route_test.dart`).
  @visibleForTesting
  static bool? debugSupportedOverride;

  static bool get isSupported =>
      debugSupportedOverride ?? (Platform.isAndroid || Platform.isIOS);

  /// Maps a platform route token to a kind. Handles BOTH vocabularies: the
  /// Android `AudioDeviceKind` type names our fork puts in `deviceId`, and
  /// the raw `AVAudioSessionPort` values iOS puts in `groupId`.
  static AudioRouteKind? kindFromToken(String? token) {
    switch (token) {
      // Android — AudioDeviceKind.typeName.
      case 'speaker':
        return AudioRouteKind.speaker;
      case 'earpiece':
        return AudioRouteKind.earpiece;
      case 'wired-headset':
        return AudioRouteKind.wired;
      case 'bluetooth':
        return AudioRouteKind.bluetooth;
      // iOS — AVAudioSessionPort raw values (inputs and outputs both, since a
      // route is identified by whichever end getSources reported).
      case 'Speaker':
        return AudioRouteKind.speaker;
      case 'Receiver':
      case 'MicrophoneBuiltIn':
        return AudioRouteKind.earpiece;
      case 'Headphones':
      case 'MicrophoneWired':
      case 'LineOut':
      case 'LineIn':
        return AudioRouteKind.wired;
      case 'BluetoothHFP':
      case 'BluetoothA2DPOutput':
      case 'BluetoothLE':
        return AudioRouteKind.bluetooth;
      case 'USBAudio':
        return AudioRouteKind.usb;
      case 'CarAudio':
        return AudioRouteKind.carAudio;
      case 'AirPlay':
        return AudioRouteKind.airplay;
    }
    return null;
  }

  static String _canonicalLabel(AudioRouteKind kind) {
    switch (kind) {
      case AudioRouteKind.speaker:
        return 'Speaker';
      case AudioRouteKind.earpiece:
        return 'Earpiece';
      case AudioRouteKind.wired:
        return 'Wired headset';
      case AudioRouteKind.bluetooth:
        return 'Bluetooth';
      case AudioRouteKind.usb:
        return 'USB audio';
      case AudioRouteKind.carAudio:
        return 'Car audio';
      case AudioRouteKind.airplay:
        return 'AirPlay';
    }
  }

  /// Built-in routes get a canonical name so the list reads consistently
  /// ("Speakerphone"/"Receiver"/"MicrophoneBuiltIn" are platform trivia).
  /// Attached devices keep the platform's name — that's where "AirPods Pro"
  /// or the car's head-unit name comes from.
  static String _label(AudioRouteKind kind, String platformLabel) {
    if (!kind.isExternal || platformLabel.trim().isEmpty) {
      return _canonicalLabel(kind);
    }
    return platformLabel.trim();
  }

  /// Every route this call could be switched to, in a stable display order
  /// (enum order) so the list doesn't reshuffle when a device connects.
  static Future<List<AudioRoute>> list() async {
    if (!isSupported) return const [];
    final List<webrtc.MediaDeviceInfo> devices;
    try {
      devices = await webrtc.navigator.mediaDevices.enumerateDevices();
    } catch (e) {
      debugPrint('[HOLLOW-ROUTE] enumerateDevices failed: $e');
      return const [];
    }

    final byKind = <AudioRouteKind, AudioRoute>{};

    if (Platform.isAndroid) {
      // audioswitch already reports exactly the available ROUTES, and its
      // deviceId IS the selector `selectAudioOutput` takes.
      for (final d in devices) {
        if (d.kind != 'audiooutput') continue;
        final kind = kindFromToken(d.deviceId);
        if (kind == null) continue;
        byKind.putIfAbsent(
          kind,
          () => AudioRoute(
              id: d.deviceId, label: _label(kind, d.label), kind: kind),
        );
      }
      return _ordered(byKind);
    }

    // iOS. Inputs FIRST: an attached headset is listed in availableInputs even
    // while a loudspeaker override is hiding it from the current route, and
    // that entry carries the UID `setPreferredInput:` needs.
    for (final d in devices) {
      if (d.kind != 'audioinput') continue;
      final kind = kindFromToken(d.groupId);
      if (kind == null) continue;
      byKind.putIfAbsent(
        kind,
        () => AudioRoute(
          id: d.deviceId,
          label: _label(kind, d.label),
          kind: kind,
          inputUid: d.deviceId,
        ),
      );
    }
    // Outputs fill in anything with no input side (plain headphones, AirPlay).
    for (final d in devices) {
      if (d.kind != 'audiooutput') continue;
      final kind = kindFromToken(d.groupId);
      if (kind == null) continue;
      byKind.putIfAbsent(
        kind,
        () =>
            AudioRoute(id: d.deviceId, label: _label(kind, d.label), kind: kind),
      );
    }
    // The loudspeaker is always reachable via a port override even when it is
    // not the live route, and getSources only reports the LIVE output.
    byKind.putIfAbsent(
      AudioRouteKind.speaker,
      () => const AudioRoute(
          id: 'Speaker', label: 'Speaker', kind: AudioRouteKind.speaker),
    );
    return _ordered(byKind);
  }

  static List<AudioRoute> _ordered(Map<AudioRouteKind, AudioRoute> byKind) {
    final out = <AudioRoute>[];
    for (final kind in AudioRouteKind.values) {
      final route = byKind[kind];
      if (route != null) out.add(route);
    }
    return out;
  }

  /// The route audio is ACTUALLY on — not the one we last asked for. The OS
  /// moves it on its own (headset hotplug, audioswitch auto-switch), so the
  /// picker's checkmark has to come from the platform.
  static Future<AudioRouteKind?> current() async {
    if (!isSupported) return null;
    try {
      return kindFromToken(await webrtc.Helper.getSelectedAudioOutput());
    } catch (e) {
      debugPrint('[HOLLOW-ROUTE] current() failed: $e');
      return null;
    }
  }

  /// Is a headset / BT / USB / CarPlay device attached right now?
  static Future<bool> hasExternalRoute() async {
    final routes = await list();
    return routes.any((r) => r.kind.isExternal);
  }

  /// Switch the live call to [route].
  static Future<void> select(AudioRoute route) async {
    if (!isSupported) return;
    try {
      if (Platform.isAndroid) {
        // audioswitch pins by device class; the id is that class's type name.
        await webrtc.Helper.selectAudioOutput(route.id);
        return;
      }
      if (route.kind == AudioRouteKind.speaker) {
        await webrtc.Helper.setSpeakerphoneOn(true);
        return;
      }
      // iOS: drop any loudspeaker override FIRST (it outranks every attached
      // device), then pin the input port — the output follows it.
      await webrtc.Helper.setSpeakerphoneOn(false);
      final uid = route.inputUid;
      if (uid != null) {
        await webrtc.Helper.selectAudioInput(uid);
      }
    } catch (e) {
      debugPrint('[HOLLOW-ROUTE] select($route) failed: $e');
    }
  }

  /// Apply Hollow's "speaker on/off" default in a headset-aware way.
  ///
  /// [loud] true = the loudest sensible route. With a headset attached that is
  /// the HEADSET, never the built-in loudspeaker: forcing the loudspeaker over
  /// a connected headset leaves the user in silence (iOS) or keeps the call on
  /// the handset for the rest of the session (Android's device pin).
  static Future<void> preferLoudRoute(bool loud) async {
    if (!isSupported) return;
    try {
      if (!loud) {
        await webrtc.Helper.setSpeakerphoneOn(false);
        return;
      }
      if (await hasExternalRoute()) {
        // "Speaker, but let bluetooth/wired win" — implemented natively on
        // both platforms.
        await webrtc.Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        await webrtc.Helper.setSpeakerphoneOn(true);
      }
    } catch (e) {
      debugPrint('[HOLLOW-ROUTE] preferLoudRoute($loud) failed: $e');
    }
  }
}

import 'dart:io';

import 'package:flutter/services.dart';
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/event_channel.dart'
    show FlutterWebRTCEventChannel;
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// libwebrtc's own warnings and errors, forwarded into hollow_debug.log.
///
/// The engine logs nothing on its own, so an audio device module that fails
/// to initialise (Linux PulseAudio, 2026-09-09) was invisible: calls connected
/// and carried no audio, with no line anywhere saying why.
class WebRtcNativeLog {
  static bool _started = false;

  /// Desktop only: the mobile plugins have no log sink method.
  static void start() {
    if (_started) return;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    _started = true;
    FlutterWebRTCEventChannel.instance.handleEvents.stream.listen((data) {
      final map = data['onLogData'];
      if (map is! Map) return;
      final line = '${map['data'] ?? ''}'.trimRight();
      if (line.isEmpty) return;
      network_api
          .logFromDart(message: '[WEBRTC-NATIVE] $line')
          .catchError((_) {});
    });
    // HOLLOW_WEBRTC_LOG=info|verbose widens it for a diagnosis run.
    final severity = Platform.environment['HOLLOW_WEBRTC_LOG'] ?? 'warning';
    const MethodChannel('FlutterWebRTC.Method')
        .invokeMethod<void>('setLogSeverity', {'severity': severity})
        .catchError((_) {});
  }
}

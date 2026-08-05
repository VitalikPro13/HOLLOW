// THROWAWAY — media forwarding D2 spike shim. DELETE after the spike.
//
// Env-gated dev harness proving a real Hollow screen share flows through the
// blind str0m forwarder spike (rust/spike_str0m) with SFrame intact:
//
//   HOLLOW_SPIKE_FWD=sharer  → capture the primary screen and offer it to the
//                              spike over its local WS signaling.
//   HOLLOW_SPIKE_FWD=viewer  → attach to the spike and render the forwarded
//                              stream in a bare dev page.
//   HOLLOW_SPIKE_ADDR=host:port  (default 127.0.0.1:9099; set to the host's
//                                 LAN ip for the VM-viewer test).
//
// Reuses the PRODUCTION media path on purpose: ScreenShareService (real
// encoder config / codec prefs / contentHint) + FrameCryptorService with a
// fixed dev key — the receive cryptor keys on the ORIGINATOR id exactly as
// step 2 keys it. Uses raw Material widgets for the dev page — acceptable
// only because this whole file is throwaway dev tooling, never shipped UI.
//
// See reports/MEDIA_FORWARDING_PLAN.md (step 3 phase 1) + the approved D2
// plan. Acceptance criteria live in rust/spike_str0m/src/main.rs.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'package:hollow/src/core/services/desktop_capture_support.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/screen_share_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;

class SpikeForwardDev {
  SpikeForwardDev._();

  /// The spike's fixed originator id — receive cryptors key on this, the
  /// same shape production uses ('screen:$originator').
  static const _originator = 'spike-sharer';

  /// No-op unless HOLLOW_SPIKE_FWD is set. Call once at boot; self-delays
  /// past app init.
  static void maybeStart() {
    final mode = Platform.environment['HOLLOW_SPIKE_FWD'];
    if (mode == null || mode.isEmpty) return;
    final addr = Platform.environment['HOLLOW_SPIKE_ADDR'] ?? '127.0.0.1:9099';
    _log('maybeStart: mode=$mode addr=$addr');
    Future.delayed(const Duration(seconds: 3), () async {
      try {
        switch (mode) {
          case 'sharer':
            await _runSharer(addr);
          case 'viewer':
            await _runViewer(addr);
          default:
            _log('unknown HOLLOW_SPIKE_FWD mode "$mode"');
        }
      } catch (e, st) {
        _log('FAILED: $e\n$st');
      }
    });
  }

  /// Log to spike_dev.log NEXT TO THE EXE — a Windows release GUI exe has no
  /// console (debugPrint is invisible even when launched from cmd), and
  /// hollow_debug.log may not exist pre-node on a fresh instance. The file is
  /// the one channel that always works.
  static void _log(String msg) {
    debugPrint('[SPIKE-DEV] $msg');
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      File('$dir\\spike_dev.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
    try {
      network_api.logFromDart(message: '[SPIKE-DEV] $msg').catchError((_) {});
    } catch (_) {}
  }

  /// Fixed 32-byte dev key (setSharedKey zeroes its input — mint fresh).
  static Uint8List _devKey() =>
      Uint8List.fromList('hollow-spike-dev-key-0123456789a'.codeUnits);

  static Future<String> _gatheredLocalSdp(RTCPeerConnection pc) async {
    for (var i = 0; i < 100; i++) {
      if (pc.iceGatheringState ==
          RTCIceGatheringState.RTCIceGatheringStateComplete) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    final desc = await pc.getLocalDescription();
    return desc!.sdp!;
  }

  static Future<void> _runSharer(String addr) async {
    _log('sharer mode — enumerating capture sources');
    final sources = await desktopCapturer.getSources(
        types: DesktopCaptureSupport.sourceTypes);
    _log('sharer: ${sources.length} sources');
    // Plain loop, not firstWhere+orElse: the runtime list is the NATIVE
    // subtype and a closure typed to the supertype fails Dart's covariant
    // generic check at runtime (analyzer-clean, runtime-fatal).
    DesktopCapturerSource? screen;
    for (final s in sources) {
      if (s.type == SourceType.Screen) {
        screen = s;
        break;
      }
    }
    screen ??= sources.first;
    _log('sharer: capturing "${screen.name}" (${screen.id})');
    final stream = await navigator.mediaDevices.getDisplayMedia({
      'video': {
        'deviceId': {'exact': screen.id},
        'mandatory': {'frameRate': 30.0, 'width': 1920, 'height': 1080},
      },
      'audio': false,
    });
    _log('sharer: capture stream up (${stream.getVideoTracks().length} track)');

    final svc = ScreenShareService(localPeerId: _originator, iceServers: const {'iceServers': []});
    final fc = FrameCryptorService();
    await fc.init(sharedKey: true);
    await fc.setSharedKey(0, _devKey());
    _log('sharer: SFrame dev key set');

    await svc.createOfferFromStream(
      stream,
      maxWidth: 1920,
      maxHeight: 1080,
      fps: 30,
      profile: ScreenContentProfile.motion,
    );
    _log('sharer: offer created');

    // SFrame on the real sender path, keyed on the originator.
    for (final sender in await svc.pc!.getSenders()) {
      if (sender.track?.kind == 'video') {
        await fc.enableForSender('screen:$_originator', sender,
            kind: 'screen_video');
      }
    }
    await fc.setKeyIndexForPeer('screen:$_originator', 0);
    _log('sharer: SFrame sender cryptor enabled');

    final sdp = await _gatheredLocalSdp(svc.pc!);
    _log('sharer: ICE gathered, connecting ws://$addr');
    final ws = await WebSocket.connect('ws://$addr');
    ws.add(jsonEncode({'type': 'hello', 'role': 'sharer'}));
    ws.add(jsonEncode({'type': 'offer', 'sdp': sdp}));
    _log('sharer: offer sent (${sdp.length} bytes) — awaiting spike answer');
    ws.listen((msg) async {
      final m = jsonDecode(msg as String) as Map<String, dynamic>;
      if (m['type'] == 'answer') {
        await svc.handleAnswer(m['sdp'] as String);
        _log('sharer: spike answer applied — STREAMING');
      }
    }, onError: (e) => _log('sharer ws error: $e'),
       onDone: () => _log('sharer ws closed'));
  }

  static Future<void> _runViewer(String addr) async {
    _log('viewer mode — attaching to spike at $addr');
    final fc = FrameCryptorService();
    await fc.init(sharedKey: true);
    await fc.setSharedKey(0, _devKey());

    final ws = await WebSocket.connect('ws://$addr');
    ws.add(jsonEncode({'type': 'hello', 'role': 'viewer'}));
    ScreenShareService? svc;
    ws.listen((msg) async {
      final m = jsonDecode(msg as String) as Map<String, dynamic>;
      if (m['type'] == 'offer') {
        svc = ScreenShareService(
            localPeerId: 'spike-viewer', iceServers: const {'iceServers': []});
        svc!.onRemoteTrackReady = () {
          _log('viewer: REMOTE TRACK READY — showing dev page');
          _showViewerPage(svc!);
        };
        await svc!.handleOffer(m['sdp'] as String);
        // Receive cryptor keys on the ORIGINATOR (step-2 keying), not on
        // the spike that delivered the packets.
        for (final receiver in await svc!.pc!.getReceivers()) {
          if (receiver.track?.kind == 'video') {
            await fc.enableForReceiver('screen:$_originator', receiver,
                kind: 'screen_video');
          }
        }
        await fc.setKeyIndexForPeer('screen:$_originator', 0);
        final sdp = await _gatheredLocalSdp(svc!.pc!);
        ws.add(jsonEncode({'type': 'answer', 'sdp': sdp}));
        _log('viewer: answer sent');
      }
    }, onError: (e) => _log('viewer ws error: $e'),
       onDone: () => _log('viewer ws closed'));
  }

  static void _showViewerPage(ScreenShareService svc) {
    final nav = hollowNavigatorKey.currentState;
    final renderer = svc.remoteRenderer;
    if (nav == null || renderer == null) {
      _log('viewer: navigator/renderer not ready — no dev page');
      return;
    }
    nav.push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: const Color(0xFF000000),
        body: Center(child: RTCVideoView(renderer)),
      ),
    ));
  }
}

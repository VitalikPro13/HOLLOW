import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/remote_track_volume.dart';

/// Keeps our capture running while nobody else is carrying our microphone.
///
/// libwebrtc records the microphone only while an audio SEND stream exists,
/// and a send stream starts only once a PeerConnection carrying our track is
/// connected. Alone in a voice channel or meeting there is none, so the
/// capture meter behind `LocalSpeakingDetector` (the self ring and the stream
/// overlay) reads nothing. This pairs two local PeerConnections that send our
/// own track from one to the other: the SAME track (no second microphone
/// handle), zero ICE servers (host candidates between two connections in this
/// process; nothing reaches the network, so Always relay is untouched), and
/// the receiving side at volume 0 BEFORE any media can flow, so we never hear
/// ourselves. The fork-side alternative (starting the audio device module
/// without a send stream) needs a rebuilt libwebrtc on two platforms and a
/// patched AudioState, which stops recording when its last send stream goes;
/// macOS ships a prebuilt framework we cannot patch at all.
class LocalMeterLoopback {
  LocalMeterLoopback._(this._sender, this._receiver);

  final RTCPeerConnection _sender;
  final RTCPeerConnection _receiver;
  bool _closed = false;

  static const Map<String, dynamic> _config = {
    'iceServers': <Map<String, dynamic>>[],
    'iceTransportPolicy': 'all',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'sdpSemantics': 'unified-plan',
  };

  /// Opens the pair and sends [track] (part of [stream]) across it. Returns
  /// once both descriptions are set; ICE and DTLS finish on their own.
  static Future<LocalMeterLoopback> open(
    MediaStreamTrack track,
    MediaStream stream, {
    void Function(String message)? log,
  }) async {
    final sender = await createPeerConnection(_config);
    RTCPeerConnection? receiver;
    try {
      receiver = await createPeerConnection(_config);
      final loop = LocalMeterLoopback._(sender, receiver);
      await loop._negotiate(track, stream, log);
      return loop;
    } catch (_) {
      await _dispose(sender);
      if (receiver != null) await _dispose(receiver);
      rethrow;
    }
  }

  Future<void> _negotiate(MediaStreamTrack track, MediaStream stream,
      void Function(String message)? log) async {
    // Candidates are held until the other side has its remote description.
    final toReceiver = _CandidateGate(_receiver);
    final toSender = _CandidateGate(_sender);
    _sender.onIceCandidate = toReceiver.add;
    _receiver.onIceCandidate = toSender.add;
    _sender.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        log?.call('[HOLLOW-VC] Meter loopback failed to connect');
      }
    };

    await _sender.addTransceiver(
      track: track,
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendOnly,
        streams: [stream],
      ),
    );
    final offer = await _sender.createOffer();
    await _sender.setLocalDescription(offer);
    await _receiver.setRemoteDescription(offer);
    await toReceiver.open();

    // Silence the receiving end while the sender still lacks an answer: no
    // packet can flow before that, so not one frame of our voice is played.
    for (final r in await _receiver.getReceivers()) {
      final t = r.track;
      if (t != null && t.kind == 'audio') await setRemoteTrackVolume(0.0, t);
    }

    final answer = await _receiver.createAnswer();
    await _receiver.setLocalDescription(answer);
    await _sender.setRemoteDescription(answer);
    await toSender.open();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _dispose(_sender);
    await _dispose(_receiver);
  }

  static Future<void> _dispose(RTCPeerConnection pc) async {
    try {
      await pc.close();
    } catch (e) {
      debugPrint('[HOLLOW-VC] Meter loopback close: $e');
    }
    try {
      await pc.dispose();
    } catch (e) {
      debugPrint('[HOLLOW-VC] Meter loopback dispose: $e');
    }
  }
}

class _CandidateGate {
  _CandidateGate(this._to);

  final RTCPeerConnection _to;
  final List<RTCIceCandidate> _held = [];
  bool _open = false;

  void add(RTCIceCandidate c) {
    if (c.candidate == null || c.candidate!.isEmpty) return;
    if (_open) {
      _to.addCandidate(c).catchError((_) {});
    } else {
      _held.add(c);
    }
  }

  Future<void> open() async {
    _open = true;
    final held = List.of(_held);
    _held.clear();
    for (final c in held) {
      await _to.addCandidate(c).catchError((_) {});
    }
  }
}

/// Keeps at most one loopback up, for the current source, while [update]
/// says we are alone; every start and stop runs strictly one after another,
/// and each settle acts on the LATEST wish, so a burst of updates coalesces.
class AloneMeterKeeper<S, H> {
  AloneMeterKeeper({
    required Future<H> Function(S source) start,
    required Future<void> Function(H handle) stop,
    void Function(String message)? log,
  })  : _start = start,
        _stop = stop,
        _log = log;

  final Future<H> Function(S source) _start;
  final Future<void> Function(H handle) _stop;
  final void Function(String message)? _log;

  S? _source;
  bool _alone = false;
  H? _handle;
  S? _runningFor;
  Future<void> _chain = Future.value();

  /// True while a loopback is up.
  bool get running => _handle != null;

  /// [source] is our live microphone (null = none); [alone] means no
  /// connected peer is carrying it.
  Future<void> update({required S? source, required bool alone}) {
    _source = source;
    _alone = alone;
    return _chain = _chain.then((_) => _settle());
  }

  /// Stops the loopback for good (leaving the room).
  Future<void> shutdown() => update(source: null, alone: false);

  Future<void> _settle() async {
    final want = _alone ? _source : null;
    final handle = _handle;
    if (handle != null && _runningFor != want) {
      _handle = null;
      _runningFor = null;
      try {
        await _stop(handle);
        _log?.call('[HOLLOW-VC] Meter loopback stopped');
      } catch (e) {
        _log?.call('[HOLLOW-VC] Meter loopback stop failed: $e');
      }
    }
    if (want != null && _handle == null) {
      try {
        _handle = await _start(want);
        _runningFor = want;
        _log?.call('[HOLLOW-VC] Meter loopback started (alone)');
      } catch (e) {
        _log?.call('[HOLLOW-VC] Meter loopback start failed: $e');
      }
    }
  }
}

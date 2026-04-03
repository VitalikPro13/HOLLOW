import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:record/record.dart' as rec;

void _vcLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// Manages WebRTC peer connections for voice channel mesh audio.
///
/// Each participant in the voice channel gets their own RTCPeerConnection.
/// Audio tracks are captured once (shared across all PCs).
/// ICE candidates and SDP are exchanged via MLS-encrypted targeted messages.
class VoiceChannelService {
  final String localPeerId;
  Map<String, dynamic> iceServers;

  /// One RTCPeerConnection per remote peer.
  final Map<String, RTCPeerConnection> _peerConnections = {};

  /// Pending ICE candidates per peer (received before remote description set).
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};

  /// Track whether remote description has been set per peer.
  final Map<String, bool> _remoteDescSet = {};

  /// Shared local audio stream (captured once, added to all PCs).
  MediaStream? _localAudioStream;
  bool _isMuted = false;

  /// Current voice channel context.
  String? _serverId;
  String? _channelId;

  /// Audio quality settings (default: voice preset).
  int opusBitrate = 32000;
  bool opusStereo = false;

  /// Device preferences.
  String? preferredAudioInputDeviceId;
  String? preferredAudioOutputDeviceId;

  /// VAD: set of currently speaking peer IDs (updated every 200ms).
  final Set<String> _speakingPeers = {};
  Timer? _vadTimer;
  /// Previous totalAudioEnergy per peer for delta calculation.
  final Map<String, double> _prevEnergy = {};

  /// Local mic amplitude monitor (record package — same as Settings mic test).
  rec.AudioRecorder? _localVadRecorder;
  StreamSubscription<rec.Amplitude>? _localVadAmpSub;
  bool _localSpeaking = false;

  /// Callback when speaking peers change.
  void Function(Set<String> speakingPeers)? onSpeakingChanged;

  VoiceChannelService({
    required this.localPeerId,
    required this.iceServers,
  });

  /// Whether this service is active (in a voice channel).
  bool get isActive => _serverId != null;

  /// Number of active peer connections.
  int get peerCount => _peerConnections.length;

  // ---------------------------------------------------------------
  //  Lifecycle
  // ---------------------------------------------------------------

  /// Start capturing audio for voice channel.
  Future<void> startAudio(String serverId, String channelId) async {
    _serverId = serverId;
    _channelId = channelId;

    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      'noiseSuppression': true,
      'autoGainControl': true,
    };
    if (preferredAudioInputDeviceId != null) {
      audioConstraints['optional'] = [
        {'sourceId': preferredAudioInputDeviceId}
      ];
      _vcLog('[HOLLOW-VC] Requesting input device: $preferredAudioInputDeviceId');
    }

    try {
      _localAudioStream = await navigator.mediaDevices.getUserMedia({
        'audio': audioConstraints,
        'video': false,
      });
      final tracks = _localAudioStream!.getAudioTracks();
      _vcLog('[HOLLOW-VC] Got local audio, tracks=${tracks.length}');
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to capture audio: $e');
      // Proceed without audio — user can still hear others.
    }

    if (preferredAudioOutputDeviceId != null) {
      try {
        await Helper.selectAudioOutput(preferredAudioOutputDeviceId!);
      } catch (_) {}
    }

    // Start VAD polling (remote peers via getStats, local via record package).
    _startVadTimer();
    _startLocalVad();
  }

  /// Initiate WebRTC connection to a peer who is already in the channel.
  /// Only call this if localPeerId < peerId (glare prevention).
  Future<void> connectToPeer(String peerId) async {
    if (_serverId == null || _channelId == null) return;

    _vcLog('[HOLLOW-VC] Creating offer for peer $peerId');
    final pc = await _createPeerConnection(peerId);
    _addLocalAudioTracks(pc);

    final offer = await pc.createOffer();
    final mungedSdp = _mungeOpusParams(offer.sdp!);
    await pc.setLocalDescription(
        RTCSessionDescription(mungedSdp, offer.type));

    final payload = jsonEncode({'sdp': mungedSdp});
    await network_api.voiceChannelSendSignal(
      serverId: _serverId!,
      channelId: _channelId!,
      peerId: peerId,
      signalType: 'sdp_offer',
      payload: payload,
    );
  }

  // ---------------------------------------------------------------
  //  Signal handling
  // ---------------------------------------------------------------

  /// Handle an incoming signal from a peer.
  Future<void> handleSignal(
    String peerId,
    String signalType,
    String payload,
    String serverId,
    String channelId,
  ) async {
    switch (signalType) {
      case 'sdp_offer':
        await _handleSdpOffer(peerId, payload, serverId, channelId);
      case 'sdp_answer':
        await _handleSdpAnswer(peerId, payload);
      case 'ice':
        await _handleIce(peerId, payload);
    }
  }

  Future<void> _handleSdpOffer(
    String peerId,
    String payload,
    String serverId,
    String channelId,
  ) async {
    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    _vcLog('[HOLLOW-VC] Received SDP offer from $peerId');
    final pc = await _createPeerConnection(peerId);
    _addLocalAudioTracks(pc);

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _remoteDescSet[peerId] = true;
    await _flushPendingCandidates(peerId);

    final answer = await pc.createAnswer();
    final mungedSdp = _mungeOpusParams(answer.sdp!);
    await pc.setLocalDescription(
        RTCSessionDescription(mungedSdp, answer.type));

    final answerPayload = jsonEncode({'sdp': mungedSdp});
    await network_api.voiceChannelSendSignal(
      serverId: serverId,
      channelId: channelId,
      peerId: peerId,
      signalType: 'sdp_answer',
      payload: answerPayload,
    );
  }

  Future<void> _handleSdpAnswer(String peerId, String payload) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;

    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    _vcLog('[HOLLOW-VC] Received SDP answer from $peerId');
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescSet[peerId] = true;
    await _flushPendingCandidates(peerId);
  }

  Future<void> _handleIce(String peerId, String payload) async {
    final v = jsonDecode(payload);
    final candidate = v['candidate'] as String? ?? '';
    final sdpMid = v['sdpMid'] as String?;
    final sdpMLineIndex = (v['sdpMLineIndex'] as num?)?.toInt();
    if (candidate.isEmpty) return;

    final ice = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);

    if (_remoteDescSet[peerId] != true ||
        _peerConnections[peerId] == null) {
      _pendingCandidates.putIfAbsent(peerId, () => []).add(ice);
      return;
    }
    try {
      await _peerConnections[peerId]!.addCandidate(ice);
    } catch (e) {
      _vcLog('[HOLLOW-VC] addCandidate failed for $peerId: $e');
    }
  }

  // ---------------------------------------------------------------
  //  Peer management
  // ---------------------------------------------------------------

  /// Called when a remote peer joins our voice channel.
  /// Determines who should create the offer (glare prevention).
  Future<void> onPeerJoinedMyChannel(String peerId) async {
    // Glare prevention: lower peer_id creates the offer.
    if (localPeerId.compareTo(peerId) < 0) {
      await connectToPeer(peerId);
    }
    // Otherwise, wait for the other peer to send us an offer.
  }

  /// Called when a remote peer leaves the voice channel.
  Future<void> onPeerLeftMyChannel(String peerId) async {
    await closePeer(peerId);
  }

  /// Close connection to a specific peer.
  Future<void> closePeer(String peerId) async {
    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      _vcLog('[HOLLOW-VC] Closing connection to $peerId');
      await pc.close();
      await pc.dispose();
    }
    _pendingCandidates.remove(peerId);
    _remoteDescSet.remove(peerId);
  }

  /// Close all connections and stop audio (leaving voice channel).
  Future<void> closeAll() async {
    _vcLog('[HOLLOW-VC] Closing all connections');
    _stopVadTimer();
    for (final peerId in _peerConnections.keys.toList()) {
      await closePeer(peerId);
    }
    if (_localAudioStream != null) {
      for (final track in _localAudioStream!.getTracks()) {
        await track.stop();
      }
      await _localAudioStream!.dispose();
      _localAudioStream = null;
    }
    _isMuted = false;
    _serverId = null;
    _channelId = null;
    _speakingPeers.clear();
    _prevEnergy.clear();
    _stopLocalVad();
  }

  // ---------------------------------------------------------------
  //  Audio controls
  // ---------------------------------------------------------------

  void setMuted(bool muted) {
    if (_localAudioStream == null) return;
    _isMuted = muted;
    for (final track in _localAudioStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
  }

  /// Mute/unmute all incoming remote audio (deafen).
  Future<void> setDeafened(bool deafened) async {
    final volume = deafened ? 0.0 : 1.0;
    for (final pc in _peerConnections.values) {
      final receivers = await pc.getReceivers();
      for (final r in receivers) {
        if (r.track?.kind == 'audio') {
          await Helper.setVolume(volume, r.track!);
        }
      }
    }
  }

  Future<void> setRemoteVolume(String peerId, double volume) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;
    final receivers = await pc.getReceivers();
    for (final r in receivers) {
      if (r.track?.kind == 'audio') {
        await Helper.setVolume(volume, r.track!);
        break;
      }
    }
  }

  // ---------------------------------------------------------------
  //  Voice Activity Detection (VAD)
  // ---------------------------------------------------------------

  void _startVadTimer() {
    _vadTimer?.cancel();
    _vadTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _pollAudioLevels();
    });
  }

  void _stopVadTimer() {
    _vadTimer?.cancel();
    _vadTimer = null;
  }

  Future<void> _pollAudioLevels() async {
    final newSpeaking = <String>{};

    // Local speech: detected by the record package amplitude monitor.
    if (!_isMuted && _localSpeaking) {
      newSpeaking.add(localPeerId);
    }

    // Check each remote peer's inbound audio via getStats.
    for (final entry in _peerConnections.entries) {
      final speaking = await _checkInboundAudio(entry.value, entry.key);
      if (speaking) newSpeaking.add(entry.key);
    }

    // Only notify if changed.
    if (!_setEquals(newSpeaking, _speakingPeers)) {
      _speakingPeers
        ..clear()
        ..addAll(newSpeaking);
      onSpeakingChanged?.call(Set.of(_speakingPeers));
    }
  }

  /// Start local mic amplitude monitoring via the record package.
  /// Same approach as the Test Microphone feature in User Settings.
  Future<void> _startLocalVad() async {
    try {
      _localVadRecorder = rec.AudioRecorder();
      final stream = await _localVadRecorder!.startStream(
        rec.RecordConfig(
          encoder: rec.AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: 16000,
          device: preferredAudioInputDeviceId != null
              ? rec.InputDevice(id: preferredAudioInputDeviceId!, label: '')
              : null,
        ),
      );
      // Drain PCM data — we only need amplitude.
      stream.listen((_) {});

      _localVadAmpSub = _localVadRecorder!
          .onAmplitudeChanged(const Duration(milliseconds: 150))
          .listen((amp) {
        // dBFS -60..0 → 0.0..1.0
        const minDb = -60.0;
        final clamped = amp.current.clamp(minDb, 0.0);
        final level = (clamped - minDb) / (0.0 - minDb);
        _localSpeaking = level > 0.30;
      });
    } catch (e) {
      _vcLog('[HOLLOW-VC] Local VAD start failed: $e');
    }
  }

  void _stopLocalVad() {
    _localVadAmpSub?.cancel();
    _localVadAmpSub = null;
    if (_localVadRecorder != null) {
      _localVadRecorder!.stop();
      _localVadRecorder!.dispose();
      _localVadRecorder = null;
    }
    _localSpeaking = false;
  }

  Future<bool> _checkInboundAudio(
      RTCPeerConnection pc, String peerId) async {
    try {
      final stats = await pc.getStats();
      for (final report in stats) {
        if (report.type == 'inbound-rtp' &&
            report.values['kind'] == 'audio') {
          return _detectSpeech(report.values, 'in-$peerId');
        }
      }
    } catch (_) {}
    return false;
  }

  /// Detect speech from an RTP stats report using totalAudioEnergy delta
  /// or direct audioLevel.
  bool _detectSpeech(Map<dynamic, dynamic> values, String key) {
    // Try audioLevel first (0.0-1.0, instantaneous).
    final level = (values['audioLevel'] as num?)?.toDouble();
    if (level != null) return level > 0.01;

    // Fall back to totalAudioEnergy delta.
    final energy =
        (values['totalAudioEnergy'] as num?)?.toDouble() ?? 0.0;
    final prev = _prevEnergy[key] ?? 0.0;
    _prevEnergy[key] = energy;
    final delta = energy - prev;
    return delta > 0.0001;
  }

  bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  // ---------------------------------------------------------------
  //  Internal
  // ---------------------------------------------------------------

  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    // Close any existing connection to this peer.
    await closePeer(peerId);

    final pc = await createPeerConnection(iceServers);
    _peerConnections[peerId] = pc;
    _remoteDescSet[peerId] = false;
    _pendingCandidates[peerId] = [];

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      if (_serverId == null || _channelId == null) return;

      final payload = jsonEncode({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
      network_api.voiceChannelSendSignal(
        serverId: _serverId!,
        channelId: _channelId!,
        peerId: peerId,
        signalType: 'ice',
        payload: payload,
      );
    };

    pc.onConnectionState = (state) {
      _vcLog('[HOLLOW-VC] Connection state with $peerId: $state');
      if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state ==
              RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        closePeer(peerId);
      }
    };

    // Remote audio plays automatically via libwebrtc default sink.
    return pc;
  }

  void _addLocalAudioTracks(RTCPeerConnection pc) {
    if (_localAudioStream == null) return;
    for (final track in _localAudioStream!.getAudioTracks()) {
      pc.addTrack(track, _localAudioStream!);
    }
  }

  Future<void> _flushPendingCandidates(String peerId) async {
    final pending = _pendingCandidates.remove(peerId);
    if (pending == null || pending.isEmpty) return;
    final pc = _peerConnections[peerId];
    if (pc == null) return;

    _vcLog('[HOLLOW-VC] Flushing ${pending.length} pending ICE candidates for $peerId');
    for (final ice in pending) {
      try {
        await pc.addCandidate(ice);
      } catch (e) {
        _vcLog('[HOLLOW-VC] addCandidate (flushed) failed: $e');
      }
    }
  }

  String _mungeOpusParams(String sdp) {
    String? opusPt;
    for (final line in sdp.split('\r\n')) {
      final match =
          RegExp(r'a=rtpmap:(\d+)\s+opus/48000', caseSensitive: false)
              .firstMatch(line);
      if (match != null) {
        opusPt = match.group(1);
        break;
      }
    }
    if (opusPt == null) return sdp;

    final params = <String>[
      'minptime=10',
      'useinbandfec=1',
      'maxaveragebitrate=$opusBitrate',
      if (opusStereo) 'stereo=1',
      if (opusStereo) 'sprop-stereo=1',
    ];

    final fmtpPrefix = 'a=fmtp:$opusPt ';
    final lines = sdp.split('\r\n');
    final result = <String>[];
    bool replaced = false;
    for (final line in lines) {
      if (line.startsWith(fmtpPrefix)) {
        result.add('$fmtpPrefix${params.join(';')}');
        replaced = true;
      } else {
        result.add(line);
      }
    }
    if (!replaced) {
      final rtpmapLine = 'a=rtpmap:$opusPt ';
      final insertResult = <String>[];
      for (final line in result) {
        insertResult.add(line);
        if (line.startsWith(rtpmapLine)) {
          insertResult.add('$fmtpPrefix${params.join(';')}');
        }
      }
      return insertResult.join('\r\n');
    }
    return result.join('\r\n');
  }
}

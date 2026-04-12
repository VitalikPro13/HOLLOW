import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
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
  String? preferredCameraDeviceId;

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

  /// Gossip mode: if true, only connect to gossipNeighbors (not all participants).
  bool gossipMode = false;

  /// Set of peer IDs that are our gossip neighbors (gossip mode only).
  Set<String> gossipNeighbors = {};

  /// Track dedup: peer IDs whose audio we've already forwarded (prevent loops).
  final Set<String> _forwardedSources = {};

  /// SFrame encryption service for voice channel E2EE.
  FrameCryptorService? frameCryptor;

  // ---------------------------------------------------------------
  //  Camera (video) support
  // ---------------------------------------------------------------

  /// Shared local camera stream (captured once, added to all PCs).
  MediaStream? _localVideoStream;
  bool _isCameraOn = false;

  /// Per-peer RTCVideoRenderer for incoming video tracks.
  final Map<String, RTCVideoRenderer> _remoteVideoRenderers = {};

  /// Per-peer remote video streams.
  final Map<String, MediaStream> _remoteVideoStreams = {};

  /// Tracks which remote video streams are synthetic (Dart-owned).
  /// Streams from onTrack event.streams.first are owned by libwebrtc and
  /// must NOT be disposed from Dart — only synthetic streams we created
  /// via createLocalMediaStream are safe to dispose.
  final Map<String, bool> _remoteVideoStreamSynthetic = {};

  /// Callback when a remote peer's video track arrives or is removed.
  void Function(String peerId, RTCVideoRenderer? renderer)? onRemoteVideoChanged;

  /// Callback when a peer's audio connection reaches connected/stable state.
  /// Used by the provider to send screen share offers after the connection is ready.
  void Function(String peerId)? onPeerConnected;

  /// Peers that need camera renegotiation once their PC reaches stable state.
  final Set<String> _pendingCameraReneg = {};

  /// Whether camera is currently on.
  bool get isCameraOn => _isCameraOn;

  /// Local camera stream (for local renderer in provider).
  MediaStream? get localVideoStream => _localVideoStream;

  VoiceChannelService({
    required this.localPeerId,
    required this.iceServers,
  });

  /// Whether this service is active (in a voice channel).
  bool get isActive => _serverId != null;

  /// Number of active peer connections.
  int get peerCount => _peerConnections.length;

  /// Set of peer IDs we currently have audio PCs with.
  Set<String> get connectedPeerIds => _peerConnections.keys.toSet();

  // ---------------------------------------------------------------
  //  Lifecycle
  // ---------------------------------------------------------------

  /// Start capturing audio for voice channel.
  Future<void> startAudio(String serverId, String channelId) async {
    _serverId = serverId;
    _channelId = channelId;

    // Initialize SFrame encryption service.
    frameCryptor = FrameCryptorService();
    await frameCryptor!.init(sharedKey: true);

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

    // Enable SFrame sender encryption on outgoing audio.
    await _enableSframeSender(peerId, pc);

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
      case 'reneg_offer':
        await _handleRenegOffer(peerId, payload, serverId, channelId);
      case 'reneg_answer':
        await _handleRenegAnswer(peerId, payload);
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

    // Enable SFrame sender encryption on outgoing audio.
    await _enableSframeSender(peerId, pc);

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

    // If camera is on, send renegotiation to add video track now that
    // the initial audio connection is established.
    _pendingCameraReneg.remove(peerId);
    if (_isCameraOn && _localVideoStream != null) {
      _vcLog('[HOLLOW-VC] Camera on — sending renegotiation to add video for $peerId (answerer)');
      _addLocalVideoTracks(pc);
      await _enableSframeSenderVideo(peerId, pc);
      await _sendRenegotiationOffer(peerId);
    }
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

    // If camera is on, send renegotiation to add video track now that
    // the initial audio connection is established (stable state).
    _pendingCameraReneg.remove(peerId); // Clear pending flag — we'll handle it now.
    if (_isCameraOn && _localVideoStream != null) {
      _vcLog('[HOLLOW-VC] Camera on — sending renegotiation to add video for $peerId');
      _addLocalVideoTracks(pc);
      await _enableSframeSenderVideo(peerId, pc);
      await _sendRenegotiationOffer(peerId);
    }
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
      // SECURITY (Phase 6.25): Cap pending ICE candidates per peer.
      final pending = _pendingCandidates.putIfAbsent(peerId, () => []);
      if (pending.length >= 100) {
        _vcLog('[HOLLOW-SECURITY] ICE candidate limit (100) reached for $peerId — dropping');
        return;
      }
      pending.add(ice);
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
    // In gossip mode, only connect to gossip neighbors.
    if (gossipMode && !gossipNeighbors.contains(peerId)) {
      return; // Not a gossip neighbor — skip (audio forwarded via neighbors).
    }
    // Already connected — skip.
    if (_peerConnections.containsKey(peerId)) return;

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
    _pendingCameraReneg.remove(peerId);

    // Clean up video renderer/stream for this peer.
    final renderer = _remoteVideoRenderers.remove(peerId);
    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
      onRemoteVideoChanged?.call(peerId, null);
    }
    final removedStream = _remoteVideoStreams.remove(peerId);
    final wasSynthetic = _remoteVideoStreamSynthetic.remove(peerId) ?? false;
    if (removedStream != null && wasSynthetic) {
      try {
        await removedStream.dispose();
      } catch (e) {
        _vcLog('[HOLLOW-VC] Stream dispose failed for $peerId (non-fatal): $e');
      }
    }

    // Phase 6.25 leak fixes: clean up per-peer state.
    _forwardedSources.remove(peerId);
    _prevEnergy.remove('in-$peerId');
    await frameCryptor?.disableForPeer(peerId);
  }

  /// Close all connections and stop audio (leaving voice channel).
  /// Enable SFrame sender encryption on outgoing audio tracks for a peer.
  Future<void> _enableSframeSender(String peerId, RTCPeerConnection pc) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) {
      // No SFrame key set yet — will enable once key arrives via MlsEpochChanged.
      return;
    }
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'audio') {
          await frameCryptor!.enableForSender(peerId, sender);
          break;
        }
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to enable SFrame sender: $e');
    }
  }

  /// Enable SFrame receiver decryption on incoming audio tracks from a peer.
  Future<void> _enableSframeReceiver(String peerId, RTCPeerConnection pc) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) return;
    try {
      final receivers = await pc.getReceivers();
      for (final receiver in receivers) {
        if (receiver.track?.kind == 'audio') {
          await frameCryptor!.enableForReceiver(peerId, receiver);
          break;
        }
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to enable SFrame receiver: $e');
    }
  }

  /// Enable SFrame sender encryption on outgoing video tracks for a peer.
  Future<void> _enableSframeSenderVideo(String peerId, RTCPeerConnection pc) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) return;
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          await frameCryptor!.enableForSender(peerId, sender, kind: 'video');
          break;
        }
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to enable SFrame video sender: $e');
    }
  }

  /// Enable SFrame receiver decryption on incoming video tracks from a peer.
  Future<void> _enableSframeReceiverVideo(String peerId, RTCPeerConnection pc) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) return;
    try {
      final receivers = await pc.getReceivers();
      for (final receiver in receivers) {
        if (receiver.track?.kind == 'video') {
          await frameCryptor!.enableForReceiver(peerId, receiver, kind: 'video');
          break;
        }
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to enable SFrame video receiver: $e');
    }
  }

  /// Handle incoming remote video track from a peer.
  Future<void> _handleRemoteVideoTrack(
    String peerId,
    RTCTrackEvent event,
    RTCPeerConnection pc,
  ) async {
    _vcLog('[HOLLOW-VC] Received video track from $peerId');

    // Get or create MediaStream for the video track.
    MediaStream stream;
    bool isSynthetic;
    if (event.streams.isNotEmpty) {
      stream = event.streams.first;
      isSynthetic = false;
    } else {
      // Windows/libwebrtc quirk: streams can be empty. Create a synthetic one.
      stream = await createLocalMediaStream('video-$peerId');
      stream.addTrack(event.track);
      isSynthetic = true;
    }

    // Dispose any existing renderer for this peer.
    final oldRenderer = _remoteVideoRenderers.remove(peerId);
    if (oldRenderer != null) {
      oldRenderer.srcObject = null;
      await oldRenderer.dispose();
    }
    // Only dispose old stream if we own it (synthetic). libwebrtc-owned
    // streams throw MediaStreamDisposeFailed when disposed from Dart.
    final oldStream = _remoteVideoStreams.remove(peerId);
    final oldWasSynthetic = _remoteVideoStreamSynthetic.remove(peerId) ?? false;
    if (oldStream != null && oldWasSynthetic) {
      try {
        await oldStream.dispose();
      } catch (e) {
        _vcLog('[HOLLOW-VC] Old stream dispose failed for $peerId (non-fatal): $e');
      }
    }

    // Create new renderer.
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    _remoteVideoRenderers[peerId] = renderer;
    _remoteVideoStreams[peerId] = stream;
    _remoteVideoStreamSynthetic[peerId] = isSynthetic;

    // Enable SFrame decryption for the video track.
    await _enableSframeReceiverVideo(peerId, pc);

    // Notify provider after a short delay (renderer needs a frame to display).
    await Future.delayed(const Duration(milliseconds: 100));
    onRemoteVideoChanged?.call(peerId, renderer);
  }

  /// Set the SFrame key and enable encryption on all existing PCs.
  /// Called when MLS epoch key arrives or changes.
  Future<void> setSframeKey(int epoch, Uint8List key) async {
    if (frameCryptor == null) return;
    await frameCryptor!.setSharedKey(epoch % 16, key); // keyRingSize=16
    // Enable on all existing peer connections.
    for (final entry in _peerConnections.entries) {
      final peerId = entry.key;
      final pc = entry.value;
      await _enableSframeSender(peerId, pc);
      await _enableSframeReceiver(peerId, pc);
      // Also enable for video if camera is on.
      if (_isCameraOn) {
        await _enableSframeSenderVideo(peerId, pc);
      }
      if (_remoteVideoRenderers.containsKey(peerId)) {
        await _enableSframeReceiverVideo(peerId, pc);
      }
    }
    _vcLog('[HOLLOW-VC] SFrame key set for epoch $epoch, enabled on ${_peerConnections.length} PCs');
  }

  Future<void> closeAll() async {
    _vcLog('[HOLLOW-VC] Closing all connections');
    _stopVadTimer();

    // Stop camera stream directly (no renegotiation — we're closing everything).
    if (_localVideoStream != null) {
      for (final track in _localVideoStream!.getTracks()) {
        await track.stop();
      }
      await _localVideoStream!.dispose();
      _localVideoStream = null;
    }
    _isCameraOn = false;

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

    // Dispose any remaining video renderers/streams.
    for (final renderer in _remoteVideoRenderers.values) {
      renderer.srcObject = null;
      await renderer.dispose();
    }
    _remoteVideoRenderers.clear();
    for (final entry in _remoteVideoStreams.entries) {
      final synthetic = _remoteVideoStreamSynthetic[entry.key] ?? false;
      if (synthetic) {
        try {
          await entry.value.dispose();
        } catch (e) {
          _vcLog('[HOLLOW-VC] Stream dispose failed for ${entry.key} (non-fatal): $e');
        }
      }
    }
    _remoteVideoStreams.clear();
    _remoteVideoStreamSynthetic.clear();

    _isMuted = false;
    _serverId = null;
    _channelId = null;
    _speakingPeers.clear();
    _prevEnergy.clear();
    _forwardedSources.clear();
    _pendingCameraReneg.clear();
    gossipMode = false;
    gossipNeighbors = {};
    await frameCryptor?.dispose();
    frameCryptor = null;
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
  //  Camera (video) controls
  // ---------------------------------------------------------------

  /// Start capturing camera and add video track to all existing PCs.
  /// Returns the local video stream for the provider to create a renderer.
  Future<MediaStream?> startCamera() async {
    if (_isCameraOn) return _localVideoStream;

    try {
      final videoConstraints = <String, dynamic>{
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 30},
      };
      // flutter_webrtc native (Windows/macOS/Linux) uses 'sourceId' in
      // optional array — 'deviceId' is ignored by GetUserVideo().
      if (preferredCameraDeviceId != null) {
        videoConstraints['optional'] = [
          {'sourceId': preferredCameraDeviceId}
        ];
      }
      _localVideoStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': videoConstraints,
      });
      _isCameraOn = true;
      _vcLog('[HOLLOW-VC] Camera started, tracks=${_localVideoStream!.getVideoTracks().length}');
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to capture camera: $e');
      return null;
    }

    final videoTrack = _localVideoStream!.getVideoTracks().first;

    // Add video track to all existing PCs and trigger renegotiation.
    for (final entry in _peerConnections.entries.toList()) {
      final peerId = entry.key;
      final pc = entry.value;

      // Only renegotiate if the PC is in stable state (initial handshake done).
      final sigState = pc.signalingState;
      if (sigState != RTCSignalingState.RTCSignalingStateStable) {
        _vcLog('[HOLLOW-VC] Skipping camera reneg for $peerId — state: $sigState (will reneg after stable)');
        _pendingCameraReneg.add(peerId);
        continue;
      }

      pc.addTrack(videoTrack, _localVideoStream!);

      // Enable SFrame encryption for the video sender.
      await _enableSframeSenderVideo(peerId, pc);

      // Renegotiate to signal the new video track.
      await _sendRenegotiationOffer(peerId);
    }

    return _localVideoStream;
  }

  /// Stop camera and remove video track from all PCs.
  Future<void> stopCamera() async {
    if (!_isCameraOn) return;
    _isCameraOn = false;

    // Remove video senders from all PCs.
    for (final entry in _peerConnections.entries.toList()) {
      final peerId = entry.key;
      final pc = entry.value;
      try {
        final senders = await pc.getSenders();
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            await pc.removeTrack(sender);
          }
        }
        // Renegotiate to signal video removal (only if stable).
        final sigState = pc.signalingState;
        if (sigState == RTCSignalingState.RTCSignalingStateStable) {
          await _sendRenegotiationOffer(peerId);
        }
      } catch (e) {
        _vcLog('[HOLLOW-VC] Error removing video sender for $peerId: $e');
      }
    }

    // Stop and dispose camera stream.
    if (_localVideoStream != null) {
      for (final track in _localVideoStream!.getTracks()) {
        await track.stop();
      }
      await _localVideoStream!.dispose();
      _localVideoStream = null;
    }
    _vcLog('[HOLLOW-VC] Camera stopped');
  }

  // ---------------------------------------------------------------
  //  Renegotiation (for adding/removing video tracks)
  // ---------------------------------------------------------------

  Future<void> _sendRenegotiationOffer(String peerId) async {
    final pc = _peerConnections[peerId];
    if (pc == null || _serverId == null || _channelId == null) return;

    try {
      final offer = await pc.createOffer();
      final mungedSdp = _mungeOpusParams(offer.sdp!);
      await pc.setLocalDescription(RTCSessionDescription(mungedSdp, offer.type));

      final payload = jsonEncode({'sdp': mungedSdp});
      await network_api.voiceChannelSendSignal(
        serverId: _serverId!,
        channelId: _channelId!,
        peerId: peerId,
        signalType: 'reneg_offer',
        payload: payload,
      );
      _vcLog('[HOLLOW-VC] Sent renegotiation offer to $peerId');
    } catch (e) {
      _vcLog('[HOLLOW-VC] Renegotiation offer failed for $peerId: $e');
    }
  }

  Future<void> _handleRenegOffer(
    String peerId,
    String payload,
    String serverId,
    String channelId,
  ) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;

    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    // Glare prevention: if we also have a pending offer, lower peerId wins.
    final sigState = pc.signalingState;
    if (sigState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      if (localPeerId.compareTo(peerId) < 0) {
        // We win — ignore their offer, they'll process our offer.
        _vcLog('[HOLLOW-VC] Reneg glare: we win ($localPeerId < $peerId), ignoring their offer');
        return;
      }
      // They win — rollback our offer.
      _vcLog('[HOLLOW-VC] Reneg glare: they win ($peerId < $localPeerId), rolling back');
      await pc.setLocalDescription(RTCSessionDescription(null, 'rollback'));
    }

    _vcLog('[HOLLOW-VC] Received renegotiation offer from $peerId');
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

    final answer = await pc.createAnswer();
    final mungedSdp = _mungeOpusParams(answer.sdp!);
    await pc.setLocalDescription(RTCSessionDescription(mungedSdp, answer.type));

    final answerPayload = jsonEncode({'sdp': mungedSdp});
    await network_api.voiceChannelSendSignal(
      serverId: serverId,
      channelId: channelId,
      peerId: peerId,
      signalType: 'reneg_answer',
      payload: answerPayload,
    );

    // After renegotiation, check if there's a remote video track we don't
    // have a renderer for. onTrack may not fire when a transceiver is reused
    // (track removed then re-added on the same m-line).
    await _checkRemoteVideoTrack(peerId, pc);
  }

  /// Check for a remote video track on a PC and create a renderer if missing.
  /// Safety net for when onTrack doesn't fire (e.g., first reneg after audio connect).
  /// Does NOT clean up renderers when video is gone — renderers survive across
  /// camera off/on cycles so the same stream can resume receiving frames.
  Future<void> _checkRemoteVideoTrack(String peerId, RTCPeerConnection pc) async {
    try {
      final receivers = await pc.getReceivers();
      for (final receiver in receivers) {
        if (receiver.track?.kind == 'video') {
          // We have a video track — do we have a renderer?
          if (!_remoteVideoRenderers.containsKey(peerId)) {
            _vcLog('[HOLLOW-VC] Found video track without renderer for $peerId — creating');
            final stream = await createLocalMediaStream('video-$peerId');
            stream.addTrack(receiver.track!);

            final renderer = RTCVideoRenderer();
            await renderer.initialize();
            renderer.srcObject = stream;
            _remoteVideoRenderers[peerId] = renderer;
            _remoteVideoStreams[peerId] = stream;
            _remoteVideoStreamSynthetic[peerId] = true; // always synthetic here

            await _enableSframeReceiverVideo(peerId, pc);

            await Future.delayed(const Duration(milliseconds: 100));
            onRemoteVideoChanged?.call(peerId, renderer);
          }
          return;
        }
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] _checkRemoteVideoTrack error: $e');
    }
  }

  Future<void> _handleRenegAnswer(String peerId, String payload) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;

    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    _vcLog('[HOLLOW-VC] Received renegotiation answer from $peerId');
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

    // Check if this peer had a pending camera renegotiation.
    await _checkPendingCameraReneg(peerId);
  }

  /// Check and send pending camera renegotiation for a peer whose PC just
  /// reached stable state.
  Future<void> _checkPendingCameraReneg(String peerId) async {
    if (!_pendingCameraReneg.remove(peerId)) return;
    if (!_isCameraOn || _localVideoStream == null) return;

    final pc = _peerConnections[peerId];
    if (pc == null) return;

    _vcLog('[HOLLOW-VC] Sending pending camera renegotiation for $peerId');
    // Only add tracks if not already present (startCamera may have added them).
    final senders = await pc.getSenders();
    final hasVideo = senders.any((s) => s.track?.kind == 'video');
    if (!hasVideo) {
      _addLocalVideoTracks(pc);
    }
    await _enableSframeSenderVideo(peerId, pc);
    await _sendRenegotiationOffer(peerId);
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
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onPeerConnected?.call(peerId);
      }
      if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state ==
              RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        closePeer(peerId);
      }
    };

    // Remote audio plays automatically via libwebrtc default sink.
    // Enable SFrame receiver decryption on incoming audio/video.
    // In gossip mode, also forward received tracks to other neighbors.
    pc.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio') {
        _enableSframeReceiver(peerId, pc);
      } else if (event.track.kind == 'video') {
        _handleRemoteVideoTrack(peerId, event, pc);
      }

      // Gossip forwarding (audio only for now).
      if (!gossipMode) return;
      if (event.track.kind != 'audio') return;

      _vcLog('[HOLLOW-VC] Gossip: received audio track from $peerId — forwarding to ${gossipNeighbors.length - 1} neighbors');

      // Track dedup: check if we already have audio from the original speaker.
      // For now, use peerId as the source identifier. In multi-hop, the
      // originator's ID would need to be signaled separately.
      if (_forwardedSources.contains(peerId)) return;
      _forwardedSources.add(peerId);

      // Forward this track to all other gossip neighbor PCs.
      final stream = event.streams.isNotEmpty
          ? event.streams.first
          : null;
      if (stream == null) return;

      for (final neighborId in gossipNeighbors) {
        if (neighborId == localPeerId || neighborId == peerId) continue;
        final neighborPc = _peerConnections[neighborId];
        if (neighborPc != null) {
          neighborPc.addTrack(event.track, stream);
          _vcLog('[HOLLOW-VC] Gossip: forwarded audio from $peerId to $neighborId');
        }
      }
    };

    return pc;
  }

  void _addLocalAudioTracks(RTCPeerConnection pc) {
    if (_localAudioStream == null) return;
    for (final track in _localAudioStream!.getAudioTracks()) {
      pc.addTrack(track, _localAudioStream!);
    }
  }

  void _addLocalVideoTracks(RTCPeerConnection pc) {
    if (_localVideoStream == null || !_isCameraOn) return;
    for (final track in _localVideoStream!.getVideoTracks()) {
      pc.addTrack(track, _localVideoStream!);
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

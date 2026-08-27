import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/ice_repair.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/services/ice_route_probe.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/core/services/link_watchdog.dart';
import 'package:hollow/src/core/services/video_quality_ladder.dart';
import 'package:hollow/src/core/services/remote_track_volume.dart';
import 'package:hollow/src/core/services/local_speaking_detector.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

void _vcLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// Manages WebRTC peer connections for voice channel mesh audio.
///
/// Each participant in the voice channel gets their own RTCPeerConnection.
/// Audio tracks are captured once (shared across all PCs).
/// ICE candidates and SDP are exchanged via MLS-encrypted targeted messages.
class VoiceChannelService {
  static const int maxVoicePcs = 15;

  final String localPeerId;
  Map<String, dynamic> iceServers;

  /// One RTCPeerConnection per remote peer.
  final Map<String, RTCPeerConnection> _peerConnections = {};

  /// Pending ICE candidates per peer (received before remote description set).
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};

  /// Track whether remote description has been set per peer.
  final Map<String, bool> _remoteDescSet = {};

  /// Guards against concurrent connectToPeer calls for the same peer (same
  /// pattern as WebRTCService._connecting). The join announcement arrives
  /// TWICE by design (MLS broadcast + plaintext member fan), and
  /// _peerConnections[peerId] is only set after the native
  /// createPeerConnection await — without this reservation the duplicate
  /// VoiceChannelJoined event slips past the containsKey guard, tears down
  /// the first PC mid-negotiation and leaves the offerer paired with a stale
  /// answer (dead mic until the next renegotiation re-syncs SDP).
  final Set<String> _connecting = {};

  /// Shared local audio stream (captured once, added to all PCs).
  MediaStream? _localAudioStream;
  bool _isMuted = false;

  /// Current voice channel context.
  String? _serverId;
  String? _channelId;

  /// Audio quality settings (default: voice preset).
  int opusBitrate = 96000;
  bool opusStereo = false;

  /// Device preferences.
  String? preferredAudioInputDeviceId;
  String? preferredAudioOutputDeviceId;
  String? preferredCameraDeviceId;

  /// Microphone input gain (0.0-2.0). Applied via SetVolume on local audio track.
  double micGain = 1.0;

  /// Voice enhancement: EQ+compressor+limiter chain in the native capture
  /// post-processor (default on; off = legacy flat makeup gain).
  bool voiceEnhance = true;

  /// Enhancement strength = the chain's compressor makeup gain in dB
  /// (0 = no loudness boost, 12 = 100% on the slider).
  double enhanceMakeupDb = 3.6;

  /// Dynamic mode: the native auto-level servo (ignores micGain/makeup).
  bool enhanceDynamic = true;

  /// AI noise suppression — user preference; see the matching fields in
  /// voice_service.dart (kept behavior-identical).
  bool noiseSuppressAi = false;

  /// Which engine (Helper.nsEngineRnnoise default / nsEngineDfn3), seeded
  /// from noiseSuppressEngineProvider.
  int noiseSuppressEngine = Helper.nsEngineRnnoise;

  /// TRUE when DFN can't run here and WebRTC's legacy NS was re-enabled in
  /// the capture constraints as the fallback.
  bool _dfnFallbackNsOn = false;

  /// WebRTC's own NS is wanted whenever DFN isn't (or can't be) doing the job.
  bool get _wantWebrtcNs => !noiseSuppressAi || _dfnFallbackNsOn;

  /// VAD: set of currently speaking peer IDs (updated every 200ms).
  final Set<String> _speakingPeers = {};
  Timer? _vadTimer;
  /// Previous totalAudioEnergy per peer for delta calculation.
  final Map<String, double> _prevEnergy = {};

  /// Are WE talking? Kept OUT of [_speakingPeers] deliberately — that set is
  /// keyed by routable device ids and the UI holds master ids, so "are we in
  /// the set" was never a reliable question. See [_pollAudioLevels].
  bool _localSpeaking = false;

  /// Callback when speaking state changes: the REMOTE peers currently
  /// speaking, and whether WE are.
  void Function(Set<String> speakingPeers, bool localSpeaking)?
      onSpeakingChanged;

  /// Gossip mode: if true, only connect to gossipNeighbors (not all participants).
  bool gossipMode = false;

  /// Set of peer IDs that are our gossip neighbors (gossip mode only).
  Set<String> gossipNeighbors = {};

  /// Track dedup: peer IDs whose audio we've already forwarded (prevent loops).
  final Set<String> _forwardedSources = {};

  /// SFrame encryption service for voice channel E2EE.
  FrameCryptorService? frameCryptor;

  /// SFrame heal hook: fired on every cryptor state transition, with the
  /// participant collapsed to the mesh peerId ('screen:X' → X). The provider
  /// runs the heal ladder off sustained failure states.
  void Function(String peerId, String kind, bool isReceiver,
      FrameCryptorState state)? onSframeCryptorState;

  // ---------------------------------------------------------------
  //  Camera (video) support
  // ---------------------------------------------------------------

  /// Shared local camera stream (captured once, added to all PCs).
  MediaStream? _localVideoStream;
  bool _isCameraOn = false;
  /// Serializes startCamera/stopCamera so a rapid stop→start can't open a new
  /// V4L2 capturer while the old one is still tearing down (libwebrtc
  /// RaceChecker aborts on /dev/video0 — see the Linux settle in stopCamera).
  Future<void> _cameraLock = Future<void>.value();
  bool _useFrontCamera = true;

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

  /// One hold-open watchdog per peer leg, created when that leg first
  /// connects. The mesh used to close a peer outright on `failed` with no
  /// recovery attempt at all, so a member whose Wi-Fi hiccuped dropped out of
  /// the channel and had to be re-invited by the join machinery.
  ///
  /// Per peer, not per channel: in a mesh, one member on hotel Wi-Fi is a
  /// problem with that member's leg, and there is no reason for it to cost
  /// anyone else their audio or their picture.
  final Map<String, LinkWatchdog> _linkWatch = {};

  /// Peers we are deliberately tearing down. `closePeer` calls `pc.close()`,
  /// which reports `closed` straight back into the state handler, and the
  /// watchdog reads that as the remote end going away.
  final Set<String> _closingPeers = {};

  /// When a rebuild of this peer's leg last began, on EITHER side.
  ///
  /// The mesh's twin of the DM lane's `_mediaRestartAt`. Both ends watch the
  /// same leg and both can decide it is broken, seconds apart: without a
  /// window, the second one to notice tears down the connection the first one
  /// had just rebuilt, and neither dials again (field-caught 2026-08-27).
  /// Claimed when we rebuild, when we ask the peer to, and when we accept a
  /// rebuild offer of theirs.
  final Map<String, DateTime> _legRebuiltAt = {};

  /// How long one rebuild owns the recovery of a leg. Comfortably longer than
  /// a PC bring-up, which is what a rebuild is.
  static const _legRebuildWindow = Duration(seconds: 10);

  /// Slow retries for legs whose whole hold-open window was spent.
  ///
  /// A DM call that gives up hangs up, and the user can call again. A voice
  /// channel has no such moment: the member is still sitting in the roster, so
  /// a leg abandoned here would be silent forever. Keyed by peer.
  final Map<String, Timer> _legRedial = {};

  /// Whether [peerId] is still in the voice channel we are in. Injected by the
  /// provider, which owns the participant sets; null means "assume yes".
  bool Function(String peerId)? isChannelParticipant;

  /// Deafen and the per-peer volumes live on the RECEIVER, not on the peer, so
  /// a rebuilt leg arrives with a brand new receiver at full volume. Held here
  /// so [_restorePeerAudioState] can put them back.
  bool _isDeafened = false;
  final Map<String, double> _peerVolumes = {};

  /// Publish a peer leg's health for the UI.
  void Function(String peerId, LinkHealthSnapshot snapshot)? onLinkHealth;

  /// Whether our relay link can carry a renegotiation offer right now.
  /// Injected by the provider so the service never reaches into Riverpod.
  bool Function()? canSignal;

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

  /// The live audio-mesh PC to [peerId], if any. Media forwarding step 3:
  /// `watchScreenShare` probes it for the viewer's route hint (direct vs
  /// relay) — read-only access, never store or close through this.
  RTCPeerConnection? pcFor(String peerId) => _peerConnections[peerId];

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
    frameCryptor!.onCryptorStateChanged = (participantId, kind, isReceiver, state) {
      // Screen-share cryptors use participant 'screen:$peerId' — collapse to
      // the mesh peer so the heal ladder tracks one entry per peer.
      final peerId = participantId.startsWith('screen:')
          ? participantId.substring('screen:'.length)
          : participantId;
      onSframeCryptorState?.call(peerId, kind, isReceiver, state);
    };

    // AI NS (DFN3): kick the engine and decide the WebRTC-NS fallback BEFORE
    // building constraints (see the matching note in voice_service.dart).
    await _syncNoiseSuppressAiEngine();
    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      // Legacy NS off while DFN3 owns suppression (unless fallback re-armed).
      'noiseSuppression': _wantWebrtcNs,
      'googNoiseSuppression': _wantWebrtcNs,
      // AGC OFF — see the matching note in voice_service.dart. WebRTC's AGC was
      // fighting our enhancement chain (conservative -18 dBFS target + desktop
      // OS-mic-slider riding), leaving the mic quiet. We own loudness in the
      // post-APM chain; AEC + NS stay on. project_voice_agc_loudness_rvox.
      'autoGainControl': false,
      'googAutoGainControl': false,
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
      _capturedAudioInputDeviceId = preferredAudioInputDeviceId;
      final tracks = _localAudioStream!.getAudioTracks();
      _vcLog('[HOLLOW-VC] Got local audio, tracks=${tracks.length}');

      // Apply mic gain via the native post-APM capture processor (makeup
      // gain + -3 dBFS limiter). Process-global, so always set it — at 1.0
      // it's transparent. NOT setVolume(): that only scales remote tracks.
      try {
        await Helper.setCaptureGain(micGain);
        await Helper.setVoiceEnhance(voiceEnhance,
            makeupDb: enhanceMakeupDb, dynamicMode: enhanceDynamic);
        _vcLog('[HOLLOW-VC] Applied capture gain: ${micGain.toStringAsFixed(2)} '
            'enhance=$voiceEnhance makeup=${enhanceMakeupDb.toStringAsFixed(1)}dB '
            'dynamic=$enhanceDynamic');
      } catch (e) {
        _vcLog('[HOLLOW-VC] Failed to apply capture gain: $e');
      }

      // NOTE: do NOT bypass Apple's Voice-Processing IO here (tried
      // 2026-07-02): it kills Apple's hardware AEC → echo everywhere and a
      // persistent feedback howl on the loudspeaker route. See
      // voice_service._captureLocalAudio for the full story.
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to capture audio: $e');
      // Proceed without audio — user can still hear others.
    }

    if (preferredAudioOutputDeviceId != null) {
      try {
        await Helper.selectAudioOutput(preferredAudioOutputDeviceId!);
      } catch (_) {}
    }

    // Start VAD polling (local + remote peers, both via getStats).
    _startVadTimer();
  }

  /// Initiate WebRTC connection to a peer who is already in the channel.
  /// Only call this if localPeerId < peerId (glare prevention).
  Future<void> connectToPeer(String peerId) async {
    if (_serverId == null || _channelId == null) return;

    _vcLog('[HOLLOW-VC] Creating offer for peer $peerId');
    final pc = await _createPeerConnection(peerId);
    try {
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
    } catch (e) {
      // A throw here leaves a live PC (already in _peerConnections) stranded —
      // dispose it so its libwebrtc thread-set can't leak.
      _vcLog('[HOLLOW-VC] connectToPeer($peerId) failed, closing PC: $e');
      await closePeer(peerId);
      rethrow;
    }
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
      case 'leg_restart':
        await _handleLegRestart(peerId);
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

    if (!_peerConnections.containsKey(peerId) && _peerConnections.length >= maxVoicePcs) {
      _vcLog('[HOLLOW-VC] Rejecting SDP offer from $peerId — voice PC cap ($maxVoicePcs) reached');
      return;
    }

    // A fresh initial offer for a leg we already hold IS the peer's rebuild.
    // Claim the window so our own watchdog does not decide, a second later,
    // to tear down the connection they have just rebuilt.
    if (_peerConnections.containsKey(peerId)) {
      _legRebuiltAt[peerId] = DateTime.now();
    }

    _vcLog('[HOLLOW-VC] Received SDP offer from $peerId');
    final pc = await _createPeerConnection(peerId);
    try {
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
    } catch (e) {
      // setRemoteDescription on an unsupported-codec SDP is a classic throw
      // point — dispose the stranded PC before propagating.
      _vcLog('[HOLLOW-VC] _handleSdpOffer($peerId) failed, closing PC: $e');
      await closePeer(peerId);
      rethrow;
    }
  }

  Future<void> _handleSdpAnswer(String peerId, String payload) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;

    final v = jsonDecode(payload);
    final sdp = v['sdp'] as String? ?? '';
    if (sdp.isEmpty) return;

    // A stable PC has no pending local offer — applying an answer would throw
    // "Called in wrong state: stable" (duplicate/late answer, e.g. after a
    // re-offer already completed). Skip it instead of surfacing a platform
    // error through the zone handler.
    if (pc.signalingState == RTCSignalingState.RTCSignalingStateStable) {
      _vcLog('[HOLLOW-VC] Ignoring SDP answer from $peerId — PC already stable');
      return;
    }

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
    // BELT: never dial ourselves — a self id reaching here is an upstream
    // participant-set bug (the self-ghost dialed our own master), and the
    // dial can only mint dead PCs + "No session" storms.
    if (peerId == localPeerId) {
      _vcLog('[HOLLOW-VC] Ignoring self id in participant dial: $peerId');
      return;
    }
    // In gossip mode, only connect to gossip neighbors.
    if (gossipMode && !gossipNeighbors.contains(peerId)) {
      return; // Not a gossip neighbor — skip (audio forwarded via neighbors).
    }
    // Already connected or mid-connect — skip (the join announcement arrives
    // twice by design: MLS broadcast + plaintext fan; see _connecting).
    if (_peerConnections.containsKey(peerId)) return;
    if (_connecting.contains(peerId)) return;
    if (_peerConnections.length >= maxVoicePcs) {
      _vcLog('[HOLLOW-VC] Voice PC cap reached ($maxVoicePcs), skipping $peerId');
      return;
    }

    // Glare prevention: lower peer_id creates the offer.
    if (localPeerId.compareTo(peerId) < 0) {
      _connecting.add(peerId);
      try {
        await connectToPeer(peerId);
      } finally {
        _connecting.remove(peerId);
      }
    }
    // Otherwise, wait for the other peer to send us an offer.
  }

  /// Called when a remote peer leaves the voice channel.
  Future<void> onPeerLeftMyChannel(String peerId) async {
    await closePeer(peerId);
  }

  /// Close connection to a specific peer.
  Future<void> closePeer(String peerId) async {
    _closingPeers.add(peerId);
    _linkWatch.remove(peerId)?.stop();
    // Whatever was last said about this leg is moot now, and a leg torn down
    // AFTER its watchdog was already gone (a give-up, then a re-dial) has
    // nothing left to retract it. Callers that mean to keep a flair up
    // republish it straight after.
    onLinkHealth?.call(peerId, const LinkHealthSnapshot());
    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      _vcLog('[HOLLOW-VC] Closing connection to $peerId');
      await pc.close();
      await pc.dispose();
    }
    _closingPeers.remove(peerId);
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
      await frameCryptor!.setKeyIndexForPeer(peerId, frameCryptor!.currentKeyIndex);
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to enable SFrame sender: $e');
    }
  }

  /// (Re)bind the SFrame receiver cryptor to the CURRENT inbound audio
  /// receiver for [peerId]. Drops the old cryptor first (enableForReceiver
  /// is idempotent per (peer, kind)) — required after the remote side swaps
  /// its mic mid-call, harmless on the initial track. Skipped before the
  /// key lands (the key-apply path binds receivers itself).
  Future<void> _rebindSframeReceiver(
      String peerId, RTCPeerConnection pc, RTCRtpReceiver? receiver) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) return;
    try {
      await frameCryptor!.disableReceiver(peerId);
      var target = receiver;
      if (target == null) {
        // Fallback: the NEWEST audio receiver (dead ones come first).
        final receivers = await pc.getReceivers();
        for (final r in receivers) {
          if (r.track?.kind == 'audio') target = r;
        }
      }
      if (target == null) return;
      await frameCryptor!.enableForReceiver(peerId, target);
      await frameCryptor!
          .setKeyIndexForPeer(peerId, frameCryptor!.currentKeyIndex);
      _vcLog('[HOLLOW-VC] SFrame receiver re-bound for $peerId');
    } catch (e) {
      _vcLog('[HOLLOW-VC] SFrame receiver rebind failed for $peerId: $e');
    }
  }

  /// Enable SFrame receiver decryption on incoming audio tracks from a peer.
  Future<void> _enableSframeReceiver(String peerId, RTCPeerConnection pc) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) return;
    try {
      final receivers = await pc.getReceivers();
      // NEWEST audio receiver wins — mid-call mic switches leave dead
      // transceivers earlier in the list.
      RTCRtpReceiver? target;
      for (final receiver in receivers) {
        if (receiver.track?.kind == 'audio') target = receiver;
      }
      if (target != null) {
        await frameCryptor!.enableForReceiver(peerId, target);
      }
      await frameCryptor!.setKeyIndexForPeer(peerId, frameCryptor!.currentKeyIndex);
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

    // The peer may have LEFT while we were awaiting initialize() above —
    // closePeer would already have run and cleared this peer's maps. Storing a
    // renderer/stream now would orphan them (no later closePeer removes them).
    // Dispose what we just built and bail.
    if (!_peerConnections.containsKey(peerId)) {
      _vcLog('[HOLLOW-VC] $peerId left during video track setup — discarding orphan renderer/stream');
      try {
        await renderer.dispose();
      } catch (_) {}
      if (isSynthetic) {
        try {
          await stream.dispose();
        } catch (_) {}
      }
      return;
    }

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
    await frameCryptor!.rotateKey(epoch % 16, key); // sets key + updates all cryptor indices
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

  /// Heal step 1: drop + re-enable [peerId]'s receiver cryptors (audio, and
  /// video when a renderer exists) and re-assert the key index. Fixes cryptors
  /// wedged on a dead transceiver or a stale index without touching the PC.
  Future<void> rebindReceiversFor(String peerId) async {
    final pc = _peerConnections[peerId];
    if (pc == null || frameCryptor == null) return;
    await _rebindSframeReceiver(peerId, pc, null);
    if (_remoteVideoRenderers.containsKey(peerId)) {
      try {
        await frameCryptor!.disableReceiver(peerId, kind: 'video');
        await _enableSframeReceiverVideo(peerId, pc);
        await frameCryptor!
            .setKeyIndexForPeer(peerId, frameCryptor!.currentKeyIndex);
      } catch (e) {
        _vcLog('[HOLLOW-VC] SFrame video receiver rebind failed for $peerId: $e');
      }
    }
  }

  Future<void> closeAll() async {
    _vcLog('[HOLLOW-VC] Closing all connections');
    _stopVadTimer();
    _connecting.clear();
    for (final t in _legRedial.values) {
      t.cancel();
    }
    _legRedial.clear();
    _legRebuiltAt.clear();
    _peerVolumes.clear();
    _isDeafened = false;

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
    Helper.setCaptureMuted(false).catchError((_) {});
    _serverId = null;
    _channelId = null;
    _speakingPeers.clear();
    _prevEnergy.clear();
    _localSpeakingDetector.reset();
    _forwardedSources.clear();
    _pendingCameraReneg.clear();
    gossipMode = false;
    gossipNeighbors = {};
    await frameCryptor?.dispose();
    frameCryptor = null;
  }

  // ---------------------------------------------------------------
  //  Audio controls
  // ---------------------------------------------------------------

  void setMuted(bool muted) {
    // Tell the capture processor first (process-global, harmless without a
    // stream): the dynamic servo FREEZES while muted so it can't adapt to
    // room bleed (e.g. shared music on speakers) and bury the voice on
    // unmute — the APM keeps processing real mic input while the track is
    // disabled.
    Helper.setCaptureMuted(muted).catchError((_) {});
    if (_localAudioStream == null) {
      _vcLog('[HOLLOW-VC] setMuted($muted) skipped — no local stream yet');
      return;
    }
    _isMuted = muted;
    for (final track in _localAudioStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    _vcLog('[HOLLOW-VC] setMuted($muted) applied to '
        '${_localAudioStream!.getAudioTracks().length} track(s)');
  }

  /// Mute/unmute all incoming remote audio (deafen).
  ///
  /// Every peer is handled independently: in a mesh, one connection that can't
  /// be silenced (closing PC, receiver whose track never carried media and so
  /// isn't in the native registry) must not abandon the peers after it —
  /// deafen would silence some voices and leave the rest playing, and the
  /// throw surfaced as a platform error in the crash log.
  Future<void> setDeafened(bool deafened) async {
    _isDeafened = deafened;
    for (final entry in _peerConnections.entries) {
      // Un-deafening restores the volume the user chose for THAT member, not a
      // flat 1.0: a peer they had turned down came back at full volume, which
      // reads as the slider forgetting itself.
      final volume = deafened ? 0.0 : (_peerVolumes[entry.key] ?? 1.0);
      try {
        final receivers = await entry.value.getReceivers();
        for (final r in receivers) {
          if (r.track?.kind == 'audio') {
            await setRemoteTrackVolume(volume, r.track!);
          }
        }
      } catch (e) {
        _vcLog('[HOLLOW-VC] Deafen skipped for ${entry.key}: $e');
      }
    }
  }

  Future<void> updateMicGain(double gain) async {
    micGain = gain;
    // Live mid-session update — native processor reads the new gain
    // atomically. Process-global, so works without a local stream too.
    await Helper.setCaptureGain(gain);
    _vcLog('[HOLLOW-VC] Updated capture gain: ${gain.toStringAsFixed(2)}');
  }

  Future<void> updateVoiceEnhance(bool enabled) async {
    voiceEnhance = enabled;
    // Live mid-session A/B toggle — same process-global atomic as the gain.
    await Helper.setVoiceEnhance(enabled,
        makeupDb: enhanceMakeupDb, dynamicMode: enhanceDynamic);
    _vcLog('[HOLLOW-VC] Updated voice enhance: $enabled');
  }

  Future<void> updateVoiceEnhanceStrength(double makeupDb) async {
    enhanceMakeupDb = makeupDb;
    await Helper.setVoiceEnhance(voiceEnhance,
        makeupDb: makeupDb, dynamicMode: enhanceDynamic);
    _vcLog('[HOLLOW-VC] Updated voice enhance strength: '
        '${makeupDb.toStringAsFixed(1)}dB');
  }

  Future<void> updateVoiceEnhanceDynamic(bool enabled) async {
    enhanceDynamic = enabled;
    await Helper.setVoiceEnhance(voiceEnhance,
        makeupDb: enhanceMakeupDb, dynamicMode: enabled);
    _vcLog('[HOLLOW-VC] Updated voice enhance dynamic: $enabled');
  }

  /// Toggle AI noise suppression live. When in a session, re-captures
  /// the mic (the WebRTC-NS constraint flipped) — mesh swap + renegotiation
  /// happen internally, unlike the DM service's caller contract.
  Future<void> updateNoiseSuppressAi(bool enabled) async {
    noiseSuppressAi = enabled;
    _dfnFallbackNsOn = false;
    await _syncNoiseSuppressAiEngine();
    _vcLog('[HOLLOW-VC] Updated AI noise suppression: $enabled');
    if (_localAudioStream == null) return;
    await _recaptureMic(_capturedAudioInputDeviceId);
  }

  /// Switch the AI-NS engine. Native swaps the engine handle in place — no
  /// constraint flip, no re-capture, no mesh reneg — safe mid-session. See
  /// voice_service.updateNoiseSuppressEngine (kept behavior-identical).
  Future<void> updateNoiseSuppressEngine(int engine) async {
    noiseSuppressEngine = engine;
    if (!noiseSuppressAi) return;
    _dfnFallbackNsOn = false;
    await _syncNoiseSuppressAiEngine();
    _vcLog('[HOLLOW-VC] Updated AI-NS engine: $engine');
  }

  /// Post-enable safety net (schedule a few seconds after enabling): if the
  /// engine reports it cannot run here while legacy NS is off, re-arm
  /// WebRTC NS and re-capture. See voice_service.reconcileNoiseSuppressAi.
  Future<void> reconcileNoiseSuppressAi() async {
    if (!noiseSuppressAi || _dfnFallbackNsOn) return;
    Map<String, dynamic> st;
    try {
      st = await Helper.getNoiseSuppressAiActive();
    } catch (_) {
      return;
    }
    // ALWAYS log — see the matching note in voice_service.dart.
    _vcLog('[HOLLOW-VC] AI-NS reconcile status: $st');
    if (st.isEmpty) return;
    final cannotRun = st['available'] != true ||
        st['bailed'] == true ||
        st['formatOk'] == false;
    if (!cannotRun) return;
    _dfnFallbackNsOn = true;
    _vcLog('[HOLLOW-VC] DFN cannot run here — falling back to WebRTC NS');
    if (_localAudioStream == null) return;
    await _recaptureMic(_capturedAudioInputDeviceId);
  }

  /// Push the AI-NS preference into the native engine and refresh the
  /// fallback decision from the engine's latched status flags.
  Future<void> _syncNoiseSuppressAiEngine() async {
    try {
      await Helper.setNoiseSuppressAi(noiseSuppressAi,
          engine: noiseSuppressEngine);
      if (noiseSuppressAi) {
        final st = await Helper.getNoiseSuppressAiActive();
        _dfnFallbackNsOn = st.isNotEmpty &&
            (st['available'] != true ||
                st['bailed'] == true ||
                st['formatOk'] == false);
        _vcLog('[HOLLOW-VC] AI-NS engine status at capture: $st '
            '(webrtcNsFallback=$_dfnFallbackNsOn)');
      } else {
        _dfnFallbackNsOn = false;
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] AI-NS engine sync failed: $e');
    }
  }

  Future<void> setRemoteVolume(String peerId, double volume) async {
    _peerVolumes[peerId] = volume;
    await _applyRemoteVolume(peerId, volume);
  }

  /// Apply a playback volume WITHOUT recording it as the user's choice — the
  /// deafen restore passes 0.0 through here, and remembering that would erase
  /// the per-peer volume it is meant to be protecting.
  Future<void> _applyRemoteVolume(String peerId, double volume) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;
    final receivers = await pc.getReceivers();
    for (final r in receivers) {
      if (r.track?.kind == 'audio') {
        await setRemoteTrackVolume(volume, r.track!);
        break;
      }
    }
  }

  /// Track ids of every connected peer's inbound audio (all the voice-channel
  /// voices). Used by the Windows entire-screen-share anti-echo path to redirect
  /// these tracks to an out-of-process renderer so they aren't re-captured.
  Future<List<String>> getAllRemoteAudioTrackIds() async {
    final ids = <String>[];
    for (final pc in _peerConnections.values) {
      final receivers = await pc.getReceivers();
      for (final r in receivers) {
        final t = r.track;
        if (t != null && t.kind == 'audio' && (t.id?.isNotEmpty ?? false)) {
          ids.add(t.id!);
        }
      }
    }
    return ids;
  }

  // ---------------------------------------------------------------
  //  Camera (video) controls
  // ---------------------------------------------------------------

  /// Start capturing camera and add video track to all existing PCs.
  /// Returns the local video stream for the provider to create a renderer.
  /// Public entry — serialized against stopCamera (shared [_cameraLock]) so a
  /// stop→start can't race two V4L2 capturers on the same device.
  Future<MediaStream?> startCamera() async {
    final prev = _cameraLock;
    final completer = Completer<void>();
    _cameraLock = completer.future;
    try {
      try {
        await prev;
      } catch (_) {}
      return await _startCameraInner();
    } finally {
      completer.complete();
    }
  }

  Future<MediaStream?> _startCameraInner() async {
    if (_isCameraOn) return _localVideoStream;

    // LINUX: if the device is still open from an earlier startCamera this
    // session (stopCamera kept it open to avoid the V4L2 reopen race), just
    // resume the existing track instead of reopening /dev/video*.
    if (Platform.isLinux && _localVideoStream != null) {
      await _resumeLinuxCameraTrack();
    }

    if (_localVideoStream == null) {
      if (!await _captureCameraStream()) return null;
    }

    final videoTrack = _localVideoStream!.getVideoTracks().first;

    // Add video track to all existing PCs and trigger renegotiation.
    await _addCameraTrackToPeers(videoTrack);

    return _localVideoStream;
  }

  /// Linux resume path for [_startCameraInner]: re-enable the still-open
  /// V4L2 track, or dispose a trackless leftover stream so capture reruns.
  Future<void> _resumeLinuxCameraTrack() async {
    final existing = _localVideoStream!.getVideoTracks().firstOrNull;
    if (existing != null) {
      existing.enabled = true;
      _isCameraOn = true;
      _vcLog('[HOLLOW-VC] Camera resumed (Linux: reused open device)');
      // Fall through to the add-track-to-PCs + reneg loop in the caller.
    } else {
      await _localVideoStream!.dispose();
      _localVideoStream = null;
    }
  }

  /// Capture the camera into [_localVideoStream] for [_startCameraInner].
  /// Returns false when getUserMedia fails (camera stays off).
  Future<bool> _captureCameraStream() async {
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
      } else {
        videoConstraints['facingMode'] =
            _useFrontCamera ? 'user' : 'environment';
      }
      _localVideoStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': videoConstraints,
      });
      _capturedCameraDeviceId = preferredCameraDeviceId;
      _isCameraOn = true;
      _vcLog('[HOLLOW-VC] Camera started, tracks=${_localVideoStream!.getVideoTracks().length}');
      return true;
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to capture camera: $e');
      return false;
    }
  }

  /// Add the freshly enabled camera track to every mesh PC and renegotiate
  /// (stable PCs only — the rest queue via [_pendingCameraReneg]).
  Future<void> _addCameraTrackToPeers(MediaStreamTrack videoTrack) async {
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

      await pc.addTrack(videoTrack, _localVideoStream!);

      // All platforms: constrain the offer to universal codecs (VP8 first).
      // Desktop builds otherwise advertise H.265/AV1 payload types that
      // break the iOS answerer; macOS additionally needs VP8-first because
      // its H.264 hw profile doesn't decode on Windows libwebrtc.
      if (videoTrack.id != null) {
        await _preferVp8ForVideoTrackOnPc(pc, videoTrack.id!);
      }

      // Enable SFrame encryption for the video sender.
      await _enableSframeSenderVideo(peerId, pc);

      // Renegotiate to signal the new video track.
      await _sendRenegotiationOffer(peerId);
    }
  }

  /// Stop camera and remove video track from all PCs. Serialized against
  /// startCamera via [_cameraLock].
  Future<void> stopCamera() async {
    final prev = _cameraLock;
    final completer = Completer<void>();
    _cameraLock = completer.future;
    try {
      try {
        await prev;
      } catch (_) {}
      await _stopCameraInner();
    } finally {
      completer.complete();
    }
  }

  Future<void> _stopCameraInner() async {
    if (!_isCameraOn) return;
    _isCameraOn = false;

    // Remove video senders from all PCs.
    await _removeVideoSendersFromPeers();

    // Stop and dispose camera stream — EXCEPT on Linux, where closing the V4L2
    // device and reopening it on the next startCamera races the libwebrtc
    // CaptureThread and ABORTS the process (video_capture_v4l2.cc:417). On Linux
    // we KEEP the device open (just pause the track via enabled=false) for the
    // whole channel session; it's released once in closeAll(), where nothing
    // reopens after. The track was already removed from all PCs above. Same
    // reasoning as VoiceService._toggleVideoLinux.
    await _releaseOrPauseCameraStream();

    // LINUX V4L2 RACE: libwebrtc's StopCapture() doesn't join its CaptureThread,
    // so dispose() returns while the OS thread still holds /dev/video0. Settle
    // here (held inside the _cameraLock critical section) so the next
    // startCamera's getUserMedia can't reopen the device mid-teardown and trip
    // the RaceChecker abort. See the matching settle in VoiceService.toggleVideo.
    if (Platform.isLinux) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  /// Remove every PC's video sender and renegotiate the stable ones
  /// (camera-off half of the addTrack/removeTrack cycle).
  Future<void> _removeVideoSendersFromPeers() async {
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
  }

  /// Camera-off stream teardown: full stop+dispose everywhere except Linux,
  /// where the V4L2 device stays open (track paused) for the session.
  Future<void> _releaseOrPauseCameraStream() async {
    if (_localVideoStream == null) return;
    if (Platform.isLinux) {
      final track = _localVideoStream!.getVideoTracks().firstOrNull;
      if (track != null) track.enabled = false;
      _vcLog('[HOLLOW-VC] Camera paused (Linux: device kept open)');
    } else {
      for (final track in _localVideoStream!.getTracks()) {
        await track.stop();
      }
      await _localVideoStream!.dispose();
      _localVideoStream = null;
      _vcLog('[HOLLOW-VC] Camera stopped');
    }
  }

  /// Local camera facing (true = front). UI reads this to mirror the local
  /// preview only for the front camera.
  bool get useFrontCamera => _useFrontCamera;

  /// Switch front/back camera (mobile). Returns the new facing (true =
  /// front) from the native side — devices with >2 cameras make a blind
  /// toggle drift out of sync.
  Future<bool> switchCamera() async {
    if (!_isCameraOn || _localVideoStream == null) return _useFrontCamera;
    final videoTracks = _localVideoStream!.getVideoTracks();
    if (videoTracks.isEmpty) return _useFrontCamera;
    _useFrontCamera = await Helper.switchCamera(videoTracks.first);
    _vcLog('[HOLLOW-VC] Camera switched, front=$_useFrontCamera');
    return _useFrontCamera;
  }

  // ---------------------------------------------------------------
  //  Live device switching (Settings picker changed mid-session)
  // ---------------------------------------------------------------

  /// Device id the live audio stream was actually captured from (dedup guard
  /// for duplicate provider listeners firing the same switch twice).
  String? _capturedAudioInputDeviceId;
  /// Device id the live camera stream was actually captured from.
  String? _capturedCameraDeviceId;

  /// Live mid-session microphone switch across the whole mesh. Captures a
  /// fresh stream, swaps every PC's audio sender via removeTrack + addTrack
  /// (NEVER replaceTrack — silently fails on Windows libwebrtc), re-binds
  /// SFrame per peer, and renegotiates each stable PC. VAD needs no attention
  /// across the swap: it reads the level off whatever track the PCs are
  /// currently sending.
  Future<void> setAudioInputDevice(String? deviceId) async {
    preferredAudioInputDeviceId = deviceId;
    if (_localAudioStream == null) return; // next session uses it
    if (_capturedAudioInputDeviceId == deviceId) return; // already live
    await _recaptureMic(deviceId);
  }

  /// Shared live mic re-capture — device switch OR an NS-constraint flip
  /// (the AI-noise-suppression toggle changes what getUserMedia must ask
  /// for). Swaps every PC in the mesh + renegotiates internally.
  Future<void> _recaptureMic(String? deviceId) async {
    // Capture the NEW mic first — if it fails, keep the old one working.
    final newStream = await _captureMicSwitchStream(deviceId);
    if (newStream == null) return;
    final newTrack = newStream.getAudioTracks().first;
    newTrack.enabled = !_isMuted; // preserve mute state across the swap

    final oldStream = _localAudioStream;
    _localAudioStream = newStream;
    _capturedAudioInputDeviceId = deviceId;

    // Re-assert the capture chain (process-global, but defensive).
    try {
      await Helper.setCaptureGain(micGain);
      await Helper.setVoiceEnhance(voiceEnhance,
          makeupDb: enhanceMakeupDb, dynamicMode: enhanceDynamic);
    } catch (_) {}

    // Swap the sender on every PC in the mesh.
    await _swapAudioSendersToTrack(newTrack, newStream);

    // Release the old mic.
    if (oldStream != null) {
      await _disposeReplacedMicStream(oldStream);
    }

    _vcLog('[HOLLOW-VC] Mic switched live to ${deviceId ?? "default"}');
  }

  /// Capture a replacement mic stream for the live switch. Returns null on
  /// getUserMedia failure or a trackless capture (old mic keeps working).
  Future<MediaStream?> _captureMicSwitchStream(String? deviceId) async {
    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      // Legacy NS off while DFN3 owns suppression (unless fallback re-armed).
      'noiseSuppression': _wantWebrtcNs,
      'googNoiseSuppression': _wantWebrtcNs,
      // AGC stays OFF — see startAudio.
      'autoGainControl': false,
      'googAutoGainControl': false,
    };
    if (deviceId != null) {
      audioConstraints['optional'] = [
        {'sourceId': deviceId}
      ];
    }
    MediaStream newStream;
    try {
      newStream = await navigator.mediaDevices
          .getUserMedia({'audio': audioConstraints, 'video': false});
    } catch (e) {
      _vcLog('[HOLLOW-VC] Mic switch: getUserMedia failed: $e');
      return null;
    }
    if (newStream.getAudioTracks().isEmpty) {
      await newStream.dispose();
      return null;
    }
    return newStream;
  }

  /// Mic-switch mesh pass: removeTrack + addTrack the new audio sender on
  /// every PC (NEVER replaceTrack), re-bind SFrame, renegotiate stable PCs.
  Future<void> _swapAudioSendersToTrack(
      MediaStreamTrack newTrack, MediaStream newStream) async {
    for (final entry in _peerConnections.entries.toList()) {
      final peerId = entry.key;
      final pc = entry.value;
      try {
        final senders = await pc.getSenders();
        for (final s in senders) {
          if (s.track?.kind == 'audio') {
            await pc.removeTrack(s);
            break;
          }
        }
        await pc.addTrack(newTrack, newStream);
        // A fresh sender needs a fresh cryptor — enableForSender is
        // idempotent per (peer, kind), so drop the dead one first.
        await frameCryptor?.disableSender(peerId);
        await _enableSframeSender(peerId, pc);
        if (pc.signalingState == RTCSignalingState.RTCSignalingStateStable) {
          await _sendRenegotiationOffer(peerId);
        } else {
          // Reneg fires once the PC settles (same path as camera enable).
          _pendingCameraReneg.add(peerId);
        }
      } catch (e) {
        _vcLog('[HOLLOW-VC] Mic switch: sender swap failed for $peerId: $e');
      }
    }
  }

  /// Stop + dispose the mic stream replaced by a live switch.
  Future<void> _disposeReplacedMicStream(MediaStream oldStream) async {
    try {
      for (final t in oldStream.getAudioTracks()) {
        await t.stop();
      }
      await oldStream.dispose();
    } catch (_) {}
  }

  /// Live mid-session camera device switch (desktop picker). NO-OP on Linux
  /// — the V4L2 device must never be closed mid-session (see stopCamera);
  /// there the new device applies on the next camera start. Returns the new
  /// camera stream when a swap happened (the provider rebinds its local
  /// preview renderer to it), null otherwise.
  Future<MediaStream?> setCameraDevice(String? deviceId) async {
    preferredCameraDeviceId = deviceId;
    if (!_isCameraOn) return null; // next enable uses it
    if (Platform.isLinux) return null;
    if (_capturedCameraDeviceId == deviceId) return null;

    final prev = _cameraLock;
    final completer = Completer<void>();
    _cameraLock = completer.future;
    try {
      try {
        await prev;
      } catch (_) {}
      if (!_isCameraOn) return null;

      // Capture the NEW camera first — on failure keep the old one.
      final newStream = await _captureCameraSwitchStream(deviceId);
      if (newStream == null) return null;
      final newTrack = newStream.getVideoTracks().first;

      final oldStream = _localVideoStream;
      _localVideoStream = newStream;
      _capturedCameraDeviceId = deviceId;

      await _swapVideoSendersToTrack(newTrack, newStream);

      // Release the old camera (never reached on Linux — guarded above).
      if (oldStream != null) {
        await _disposeReplacedCameraStream(oldStream);
      }
      _vcLog('[HOLLOW-VC] Camera switched live to ${deviceId ?? "default"}');
      return newStream;
    } finally {
      completer.complete();
    }
  }

  /// Capture a replacement camera stream for the live switch. Returns null
  /// on getUserMedia failure or a trackless capture (old camera kept).
  Future<MediaStream?> _captureCameraSwitchStream(String? deviceId) async {
    final videoConstraints = <String, dynamic>{
      'width': {'ideal': 640},
      'height': {'ideal': 480},
      'frameRate': {'ideal': 30},
    };
    if (deviceId != null) {
      videoConstraints['optional'] = [
        {'sourceId': deviceId}
      ];
    }
    MediaStream newStream;
    try {
      newStream = await navigator.mediaDevices
          .getUserMedia({'audio': false, 'video': videoConstraints});
    } catch (e) {
      _vcLog('[HOLLOW-VC] Camera switch: getUserMedia failed: $e');
      return null;
    }
    if (newStream.getVideoTracks().isEmpty) {
      await newStream.dispose();
      return null;
    }
    return newStream;
  }

  /// Camera-switch mesh pass: swap every PC's video sender to the new track
  /// (removeTrack + addTrack), re-apply VP8-first, re-bind SFrame video and
  /// renegotiate stable PCs.
  Future<void> _swapVideoSendersToTrack(
      MediaStreamTrack newTrack, MediaStream newStream) async {
    for (final entry in _peerConnections.entries.toList()) {
      final peerId = entry.key;
      final pc = entry.value;
      try {
        final senders = await pc.getSenders();
        for (final s in senders) {
          if (s.track?.kind == 'video') {
            await pc.removeTrack(s);
          }
        }
        await pc.addTrack(newTrack, newStream);
        // Same VP8-first constraint as every camera enable (iOS answerer).
        if (newTrack.id != null) {
          await _preferVp8ForVideoTrackOnPc(pc, newTrack.id!);
        }
        await frameCryptor?.disableSender(peerId, kind: 'video');
        await _enableSframeSenderVideo(peerId, pc);
        if (pc.signalingState ==
            RTCSignalingState.RTCSignalingStateStable) {
          await _sendRenegotiationOffer(peerId);
        } else {
          _pendingCameraReneg.add(peerId);
        }
      } catch (e) {
        _vcLog(
            '[HOLLOW-VC] Camera switch: sender swap failed for $peerId: $e');
      }
    }
  }

  /// Stop + dispose the camera stream replaced by a live switch.
  Future<void> _disposeReplacedCameraStream(MediaStream oldStream) async {
    try {
      for (final t in oldStream.getTracks()) {
        await t.stop();
      }
      await oldStream.dispose();
    } catch (_) {}
  }

  /// Live audio output (speaker) switch. selectAudioOutput is process-global
  /// on desktop, so this applies to the session immediately.
  Future<void> setAudioOutputDevice(String? deviceId) async {
    preferredAudioOutputDeviceId = deviceId;
    if (deviceId == null) return; // system default — applies on next session
    try {
      await Helper.selectAudioOutput(deviceId);
      _vcLog('[HOLLOW-VC] Audio output switched live to $deviceId');
    } catch (e) {
      _vcLog('[HOLLOW-VC] Audio output switch failed: $e');
    }
  }

  // ---------------------------------------------------------------
  //  Renegotiation (for adding/removing video tracks)
  // ---------------------------------------------------------------

  Future<void> _sendRenegotiationOffer(String peerId,
      {bool iceRestart = false}) async {
    final pc = _peerConnections[peerId];
    if (pc == null || _serverId == null || _channelId == null) return;

    try {
      final offer = await pc.createOffer();
      final mungedSdp = _mungeOpusParams(offer.sdp!);
      await pc.setLocalDescription(RTCSessionDescription(mungedSdp, offer.type));

      // `ice_restart` tells the answerer this re-offer carries no media
      // change, so it must not run its camera-track safety net (which would
      // otherwise invent a camera tile for us — see the flag's doc in types.rs).
      final payload = jsonEncode({'sdp': mungedSdp, 'ice_restart': iceRestart});
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
    // An ICE-restart re-offer changes no m-lines; running the camera safety
    // net below would materialise a renderer for the peer's INACTIVE video
    // transceiver and show a phantom camera tile (field-observed 2026-08-15,
    // caused by the "direct whenever direct is possible" repair).
    final iceRestart = v['ice_restart'] as bool? ?? false;

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
    // (track removed then re-added on the same m-line). NOT for an ICE
    // restart: nothing about the media changed, so anything this found would
    // be a transceiver that was already there and already idle.
    if (!iceRestart) {
      await _checkRemoteVideoTrack(peerId, pc);
    }
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

    // LOCAL: the native capture meter — one process-global read, no peer
    // connection required, so it also lights up while you are alone in the
    // channel. See [LocalSpeakingDetector] for why not getStats/`record`.
    //
    // Reported as its OWN flag rather than as our peer id inside the set,
    // mirroring the 1:1 call path: the set is keyed by ROUTABLE device ids
    // and the UI often holds the MASTER id, so a membership test for
    // ourselves silently missed and the self indicator never lit.
    var newLocal = await _localSpeakingDetector.poll(muted: _isMuted);

    // REMOTE: one getStats pass per peer connection. Where the plugin has no
    // capture meter (an app updated ahead of its native side) the same pass
    // also carries the old outgoing-level guess.
    var wantLocal = !_isMuted && !_localSpeakingDetector.hasMeter;

    for (final entry in _peerConnections.entries) {
      final levels = await _checkAudioLevels(entry.value, entry.key,
          wantLocal: wantLocal);
      if (levels.remote) newSpeaking.add(entry.key);
      if (levels.localReported) {
        wantLocal = false;
        if (levels.local) newLocal = true;
      }
    }

    // Only notify if changed.
    if (newLocal != _localSpeaking ||
        !_setEquals(newSpeaking, _speakingPeers)) {
      _localSpeaking = newLocal;
      _speakingPeers
        ..clear()
        ..addAll(newSpeaking);
      onSpeakingChanged?.call(Set.of(_speakingPeers), _localSpeaking);
    }
  }

  /// One-shot diagnostic, twin of the one in `voice_service.dart` — see its
  /// comment. Logged once per session so a single test run settles whether
  /// this platform's getStats carries an outgoing audio level at all.
  bool _vadStatsLogged = false;

  /// Our own speaking state, from the native capture meter (issue #37).
  final _localSpeakingDetector = LocalSpeakingDetector();

  void _logVadStatsOnce(List<StatsReport> stats) {
    if (_vadStatsLogged) return;
    _vadStatsLogged = true;
    final lines = <String>[];
    for (final report in stats) {
      if (report.values['kind'] != 'audio') continue;
      if (report.type != 'media-source' &&
          report.type != 'outbound-rtp' &&
          report.type != 'inbound-rtp') {
        continue;
      }
      lines.add('${report.type}: audioLevel=${report.values['audioLevel']} '
          'totalAudioEnergy=${report.values['totalAudioEnergy']} '
          'keys=${report.values.keys.join(",")}');
    }
    _vcLog('[HOLLOW-VAD-DIAG] '
        '${lines.isEmpty ? "no audio reports" : lines.join(" | ")}');
  }

  /// One getStats pass over [pc]: that peer's inbound audio, plus — when
  /// [wantLocal] — our own outgoing level from the same report set.
  ///
  /// Local detection deliberately rides the peer connection instead of a
  /// second mic handle. The old path opened a `record` AudioRecorder purely
  /// to read amplitude; `record_linux` shells out to `parecord`, which isn't
  /// installed on PipeWire systems, so the constructor threw and every Linux
  /// user's OWN speaking indicator stayed dark while remote peers' worked
  /// (issue #37). Reading the level off the PC also puts voice channels on
  /// the exact same detector and threshold as 1:1 calls
  /// (`voice_service.dart::_pollVad`), which the two paths previously
  /// disagreed on: `record` reports PEAK dBFS pre-processing, getStats
  /// reports RMS post-processing, so the same voice tripped them differently.
  ///
  /// [localReported] distinguishes "this PC says we're silent" from "this PC
  /// carried no outgoing audio report at all" — only the former ends the
  /// search, so a receive-only or not-yet-flowing PC falls through to the
  /// next one instead of pinning us silent.
  Future<({bool remote, bool local, bool localReported})> _checkAudioLevels(
    RTCPeerConnection pc,
    String peerId, {
    required bool wantLocal,
  }) async {
    var remote = false;
    var local = false;
    var localReported = false;
    try {
      final stats = await pc.getStats();
      _logVadStatsOnce(stats);
      for (final report in stats) {
        if (report.values['kind'] != 'audio') continue;
        switch (report.type) {
          case 'inbound-rtp':
            remote = _detectSpeech(report.values, 'in-$peerId');
          // Local: media-source carries audioLevel on Android, outbound-rtp
          // on desktop. Take either — same as the 1:1 call path. They keep
          // SEPARATE energy keys so the totalAudioEnergy fallback of one
          // can't consume the other's delta within a single poll.
          case 'media-source':
            if (wantLocal) {
              local |= _detectSpeech(report.values, 'out-src');
              localReported = true;
            }
          case 'outbound-rtp':
            if (wantLocal) {
              local |= _detectSpeech(report.values, 'out-rtp');
              localReported = true;
            }
        }
      }
    } catch (_) {}
    return (remote: remote, local: local, localReported: localReported);
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

    pc.onIceCandidate = (candidate) => _onLocalIceCandidate(peerId, candidate);
    pc.onConnectionState = (state) =>
        _onPeerConnectionState(peerId, pc, state);
    // Remote audio plays automatically via libwebrtc default sink.
    // Enable SFrame receiver decryption on incoming audio/video.
    // In gossip mode, also forward received tracks to other neighbors.
    pc.onTrack = (RTCTrackEvent event) => _onPeerTrack(peerId, pc, event);

    return pc;
  }

  /// onIceCandidate handler: relay each locally gathered candidate to the
  /// peer over the MLS-encrypted signal channel.
  void _onLocalIceCandidate(String peerId, RTCIceCandidate candidate) {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
    if (_serverId == null || _channelId == null) return;

    final payload = jsonEncode({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
    // .catchError, not try/catch: fire-and-forget — a sync try/catch around
    // the un-awaited Future catches nothing. Safe to swallow: ICE candidates
    // are best-effort (the connection retries/renegotiates without this one).
    network_api.voiceChannelSendSignal(
      serverId: _serverId!,
      channelId: _channelId!,
      peerId: peerId,
      signalType: 'ice',
      payload: payload,
    ).catchError((_) {});
  }

  /// onConnectionState handler: fire onPeerConnected + a delayed ICE-route
  /// log on connect; tear the PC down on failed/closed.
  void _onPeerConnectionState(
      String peerId, RTCPeerConnection pc, RTCPeerConnectionState state) {
    _vcLog('[HOLLOW-VC] Connection state with $peerId: $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      onPeerConnected?.call(peerId);
      _logIceRoute(peerId, pc);
      scheduleIceRepair(peerId);
      // Clear the flair explicitly: a leg we had given up on is republished as
      // `lost`, and the FRESH watchdog that replaces it starts out believing
      // it has already published "healthy", so it would never say so.
      onLinkHealth?.call(peerId, const LinkHealthSnapshot());
      _startLinkWatch(peerId);
      // The leg is back: stop reaching for it, and put back the receive-side
      // state the fresh receiver does not carry (deafen, per-peer volume).
      _legRedial.remove(peerId)?.cancel();
      unawaited(_restorePeerAudioState(peerId));
    }
    // Our own teardown reports `closed` right back here; that is not the
    // remote end going away.
    if (_closingPeers.contains(peerId)) return;

    final watch = _linkWatch[peerId];
    if (watch != null) {
      // The leg has been up before, so trouble now earns the hold-open ladder:
      // hold it, restart ICE, and only close the peer once the window is spent.
      watch.noteTransportState(state);
      return;
    }
    // Never connected: this is a setup failure for this leg, and the mesh's
    // own join machinery is what retries it.
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
        state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
      closePeer(peerId);
    }
  }

  /// Begin holding [peerId]'s leg open across network trouble. Idempotent:
  /// a leg that reconnects keeps the watchdog it already had.
  void _startLinkWatch(String peerId) {
    if (_linkWatch.containsKey(peerId)) return;
    _linkWatch[peerId] = LinkWatchdog(
      label: 'VC-LINK',
      log: _vcLog,
      peerConnection: () => _peerConnections[peerId],
      isPolite: shouldInitiateIceRepair(localPeerId, peerId),
      onHealth: (snapshot) => onLinkHealth?.call(peerId, snapshot),
      onRecoverLink: () => _rebuildLeg(peerId),
      onApplyRung: (rung) => applyVideoRungFor(peerId, rung),
      canSignal: canSignal,
      onGiveUp: () {
        _vcLog('[HOLLOW-VC] $peerId: hold-open window spent, closing the leg');
        unawaited(closePeer(peerId).then((_) {
          // `closePeer` stops the watchdog, and a stopped watchdog publishes a
          // HEALTHY snapshot — which would wipe the flair off a member we can
          // no longer hear at all. Say what is true and keep saying it until
          // the leg is actually back.
          onLinkHealth?.call(
              peerId, const LinkHealthSnapshot(health: LinkHealth.lost));
        }));
        // Not the end of the story the way a DM hangup is: this member is
        // still sitting in the channel, so keep trying to reach them.
        _scheduleLegRedial(peerId);
      },
    )..start();
  }

  /// Rebuild the media leg to [peerId] without leaving the channel.
  ///
  /// The mesh's version of the DM lane's `_restartMediaSession`: drop the leg
  /// and bring it up again from scratch, which is exactly what a member
  /// joining does. `_createPeerConnection` closes any existing PC first, so
  /// the fresh offer rebuilds BOTH ends, and both get new SFrame cryptors
  /// created in the known-good order rather than repaired in place.
  ///
  /// The mesh gives the offer to the lexicographically LOWER id (the glare
  /// rule `onPeerJoinedMyChannel` dials by). That left the higher side with no
  /// recovery at all: it closed its leg and then waited for an offer nobody
  /// was going to send. It asks now, with [_sendLegRestart].
  Future<void> _rebuildLeg(String peerId) async {
    if (_serverId == null || _channelId == null) return;
    if (_legRebuiltRecently(peerId)) {
      _vcLog('[HOLLOW-VC] $peerId: a leg rebuild is already under way — '
          'standing down rather than crossing it');
      return;
    }
    _legRebuiltAt[peerId] = DateTime.now();
    if (shouldInitiateIceRepair(localPeerId, peerId)) {
      await _redialLeg(peerId);
      return;
    }
    _vcLog('[HOLLOW-VC] $peerId: asking them to rebuild the leg (they dial)');
    await _sendLegRestart(peerId);
  }

  /// Whether a rebuild of this leg began recently enough to still own it.
  bool _legRebuiltRecently(String peerId) {
    final at = _legRebuiltAt[peerId];
    return at != null && DateTime.now().difference(at) < _legRebuildWindow;
  }

  /// Tear the leg down and offer a fresh one. Only ever called on the DIALING
  /// side: two crossing rebuilds would ping-pong closing each other's fresh
  /// peer connection, since `_createPeerConnection` closes what it finds.
  Future<void> _redialLeg(String peerId) async {
    _vcLog('[HOLLOW-VC] $peerId: rebuilding the leg (we dial)');
    await closePeer(peerId);
    // `closePeer` stops the watchdog, and a stopped watchdog publishes HEALTHY
    // — so without this the flair blinks off for the whole rebuild, exactly
    // when the member is least able to hear us. The connect handler clears it.
    onLinkHealth?.call(
        peerId, const LinkHealthSnapshot(health: LinkHealth.reconnecting));
    if (_serverId == null || _channelId == null) return;
    if (_connecting.contains(peerId)) return;
    _connecting.add(peerId);
    try {
      await connectToPeer(peerId);
    } catch (e) {
      _vcLog('[HOLLOW-VC] $peerId: leg rebuild dial failed: $e');
      onLinkHealth?.call(
          peerId, const LinkHealthSnapshot(health: LinkHealth.lost));
    } finally {
      _connecting.remove(peerId);
    }
  }

  /// Ask [peerId] to re-offer the leg between us.
  Future<void> _sendLegRestart(String peerId) async {
    if (_serverId == null || _channelId == null) return;
    try {
      await network_api.voiceChannelSendSignal(
        serverId: _serverId!,
        channelId: _channelId!,
        peerId: peerId,
        signalType: 'leg_restart',
        payload: '{}',
      );
    } catch (e) {
      _vcLog('[HOLLOW-VC] leg_restart to $peerId failed: $e');
    }
  }

  /// [peerId] cannot dial us (we hold the lower id) and is asking for a fresh
  /// leg.
  Future<void> _handleLegRestart(String peerId) async {
    if (!shouldInitiateIceRepair(localPeerId, peerId)) {
      // Only the dialing side may act on this. Honouring it here would mint a
      // second dialer and put us straight back into the glare this avoids.
      _vcLog('[HOLLOW-VC] Ignoring leg_restart from $peerId — they are the '
          'dialing side, not us');
      return;
    }
    if (_legRebuiltRecently(peerId)) {
      _vcLog('[HOLLOW-VC] $peerId asked for a leg rebuild, but one is already '
          'under way — standing down');
      return;
    }
    _legRebuiltAt[peerId] = DateTime.now();
    _vcLog('[HOLLOW-VC] $peerId asked us to rebuild the leg');
    await _redialLeg(peerId);
  }

  /// Keep reaching for a leg whose hold-open window was spent.
  ///
  /// Slow on purpose: a leg only reaches here after the ladder has held it for
  /// the full window, so the network is properly down rather than wobbling.
  /// Stops on its own once the leg comes back (the watchdog owns it again) or
  /// the member leaves the channel.
  void _scheduleLegRedial(String peerId, {int attempt = 1}) {
    _legRedial.remove(peerId)?.cancel();
    final seconds = (10 * attempt).clamp(10, 60);
    _legRedial[peerId] = Timer(Duration(seconds: seconds), () async {
      _legRedial.remove(peerId);
      if (!isActive) return;
      if (isChannelParticipant?.call(peerId) == false) {
        _vcLog('[HOLLOW-VC] $peerId left the channel — giving up the re-dial');
        return;
      }
      // A live watchdog means the leg connected again and is being held open
      // by the ladder; this retry has nothing left to do.
      if (_linkWatch.containsKey(peerId)) return;
      if (canSignal?.call() == false) {
        // Our own relay link is down, so the offer would be dropped before it
        // left the machine. Wait rather than spend an attempt on nothing.
        _scheduleLegRedial(peerId, attempt: attempt);
        return;
      }
      _vcLog('[HOLLOW-VC] $peerId: reaching for the leg again '
          '(attempt $attempt)');
      _legRebuiltAt.remove(peerId);
      await _rebuildLeg(peerId);
      _scheduleLegRedial(peerId, attempt: attempt + 1);
    });
  }

  /// Put back what a fresh receiver does not carry over.
  ///
  /// Mute rides the shared local track and survives a rebuild untouched, but
  /// deafen and any per-peer volume are set ON the receiver, which the rebuild
  /// replaced — without this, un-deafening was the only way to get a rebuilt
  /// leg back to the volume the user had chosen.
  Future<void> _restorePeerAudioState(String peerId) async {
    double wanted() => _isDeafened ? 0.0 : (_peerVolumes[peerId] ?? 1.0);
    if (wanted() == 1.0) return;
    _vcLog('[HOLLOW-VC] Restoring playback volume ${wanted()} for $peerId');
    await _applyRemoteVolume(peerId, wanted());
    // Re-assert once the track has actually carried a packet: a receiver whose
    // track has never delivered media is not in the platform's registry yet,
    // and `setVolume` on it is a TOLERATED no-op rather than an error, so the
    // first attempt can vanish without a sound. Silently leaving a deafened
    // member audible is the failure worth the second call.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!_peerConnections.containsKey(peerId)) return;
    if (wanted() == 1.0) return;
    await _applyRemoteVolume(peerId, wanted());
  }

  /// Hold the camera we send to ONE peer to [rung].
  ///
  /// Per peer, because in a mesh each leg has its own sender and its own
  /// uplink problem. One member on a bad connection gets a smaller picture of
  /// us; nobody else pays for it.
  Future<bool> applyVideoRungFor(String peerId, VideoRung rung) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return false;
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind != 'video') continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) return false;
        for (final e in encodings) {
          e.active = !rung.isPaused;
          e.maxBitrate = rung.isPaused ? null : rung.maxBitrateBps;
          e.maxFramerate = rung.maxFramerate;
          e.scaleResolutionDownBy = rung.scaleDownBy;
        }
        params.degradationPreference =
            RTCDegradationPreference.MAINTAIN_RESOLUTION;
        final ok = await sender.setParameters(params);
        _vcLog('[HOLLOW-VC] $peerId video rung "${rung.label}" accepted=$ok');
        return ok;
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] applyVideoRungFor($peerId) failed: $e');
    }
    return false;
  }

  /// Log which ICE route (TURN/STUN/LAN) the succeeded candidate pair took.
  /// Diagnostics only.
  Future<void> _logIceRoute(String peerId, RTCPeerConnection pc) async {
    final route = await probeIceRoute(() => pc);
    _vcLog(route == null
        ? '[HOLLOW-VC] ICE route to $peerId: no succeeded candidate pair found'
        : '[HOLLOW-VC] ICE route to $peerId: $route');
  }

  /// Peers whose one-shot ICE repair has already been spent this session.
  final Set<String> _iceRepairDone = {};

  /// Peers with a renegotiation we started in flight. The mesh has no
  /// `_renegotiationInProgress` equivalent — glare is normally arbitrated
  /// inline by signalingState + the peer-id tiebreak — but an ICE restart is a
  /// NEW renegotiation source, so it gets an explicit busy flag rather than
  /// leaning on that tiebreak.
  final Set<String> _renegInFlight = {};

  /// Whether "Always relay calls" is on — injected by the provider so the
  /// service never reaches into Riverpod. Forced-relay users must NEVER be
  /// repaired to direct: that routing is a deliberate privacy choice.
  bool Function()? isForcedRelay;

  /// One-shot "direct whenever direct is possible" repair for a mesh PC.
  /// See `ice_repair.dart` for why the nomination race makes this necessary
  /// and why exactly one attempt is the right budget.
  ///
  /// This is the highest-value lane for the repair: a VC audio PC repaired to
  /// direct is also what flips the screen-share `route` hint to `direct`,
  /// which lets the sharer promote this viewer onto a peer branch (lever 2).
  void scheduleIceRepair(String peerId, {int attempt = 0}) {
    if (_iceRepairDone.contains(peerId)) return;
    if (isForcedRelay?.call() ?? false) return;
    if (!shouldInitiateIceRepair(localPeerId, peerId)) {
      _iceRepairDone.add(peerId); // the other side owns the attempt
      return;
    }
    Future<void>.delayed(
      attempt == 0 ? const Duration(seconds: 10) : const Duration(seconds: 5),
      () async {
        if (_iceRepairDone.contains(peerId)) return;
        final pc = _peerConnections[peerId];
        if (pc == null) return;

        // Quiescent window only (see the DM-lane twin): no renegotiation of
        // ours in flight, and the PC settled in `stable`.
        final busy = _renegInFlight.contains(peerId) ||
            _pendingCameraReneg.contains(peerId) ||
            pc.signalingState != RTCSignalingState.RTCSignalingStateStable;
        if (busy) {
          if (attempt < 5) {
            scheduleIceRepair(peerId, attempt: attempt + 1);
          } else {
            _vcLog('[HOLLOW-ICE-REPAIR] $peerId: no quiet window — '
                'accepting the relayed pair');
            _iceRepairDone.add(peerId);
          }
          return;
        }

        final verdict = await assessIceRepair(pc);
        if (verdict == null) return;
        if (!verdict.shouldRepair) {
          _iceRepairDone.add(peerId);
          return;
        }

        _iceRepairDone.add(peerId); // one attempt, whatever happens
        _vcLog('[HOLLOW-ICE-REPAIR] $peerId: relayed pair with direct '
            'candidates both sides (${verdict.detail}) — restarting ICE');
        if (!await restartIceOn(pc)) return;
        _renegInFlight.add(peerId);
        try {
          await _sendRenegotiationOffer(peerId, iceRestart: true);
        } finally {
          _renegInFlight.remove(peerId);
        }

        final after = await probeIceRoute(() => _peerConnections[peerId]);
        _vcLog(after == null
            ? '[HOLLOW-ICE-REPAIR] $peerId: post-restart route unknown'
            : after.isDirect
                ? '[HOLLOW-ICE-REPAIR] $peerId: repaired to direct: $after'
                : '[HOLLOW-ICE-REPAIR] $peerId: still relayed: $after');
        onIceRouteRepaired?.call(peerId, after?.isDirect ?? false);
      },
    );
  }

  /// Fired after a repair attempt settles (direct = true when it worked) so
  /// the provider can refresh anything keyed on the route — notably the
  /// screen-watch hint (lever 2 of the pair).
  void Function(String peerId, bool direct)? onIceRouteRepaired;

  /// onTrack handler: bind SFrame receivers for the new audio/video track,
  /// then (gossip mode only) forward received audio to other neighbors.
  void _onPeerTrack(String peerId, RTCPeerConnection pc, RTCTrackEvent event) {
    if (event.track.kind == 'audio') {
      // REBIND, not just enable: a remote mid-call mic switch lands as a
      // NEW transceiver, and _enableSframeReceiver is idempotent per
      // (peer, kind) — it would silently keep the cryptor on the dead
      // receiver and the fresh track plays as ciphertext gibberish.
      unawaited(_rebindSframeReceiver(peerId, pc, event.receiver));
    } else if (event.track.kind == 'video') {
      _handleRemoteVideoTrack(peerId, event, pc);
    }

    _forwardGossipAudio(peerId, event);
  }

  /// Gossip forwarding (audio only for now): re-add a neighbor's inbound
  /// audio track to every other gossip neighbor PC, deduped per source.
  void _forwardGossipAudio(String peerId, RTCTrackEvent event) {
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
    final opusPt = _findOpusPayloadType(sdp);
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
      return _insertOpusFmtpLine(
          result, opusPt, '$fmtpPrefix${params.join(';')}');
    }
    return result.join('\r\n');
  }

  /// Payload type of the opus/48000 rtpmap entry, or null if absent.
  String? _findOpusPayloadType(String sdp) {
    for (final line in sdp.split('\r\n')) {
      final match =
          RegExp(r'a=rtpmap:(\d+)\s+opus/48000', caseSensitive: false)
              .firstMatch(line);
      if (match != null) {
        return match.group(1);
      }
    }
    return null;
  }

  /// No existing a=fmtp line for opus — insert [fmtpLine] right after the
  /// opus rtpmap line and rejoin the SDP.
  String _insertOpusFmtpLine(
      List<String> lines, String opusPt, String fmtpLine) {
    final rtpmapLine = 'a=rtpmap:$opusPt ';
    final insertResult = <String>[];
    for (final line in lines) {
      insertResult.add(line);
      if (line.startsWith(rtpmapLine)) {
        insertResult.add(fmtpLine);
      }
    }
    return insertResult.join('\r\n');
  }

  /// Constrain the transceiver carrying [trackId] on [pc] to VP8 only (plus
  /// rtx/red/ulpfec). VP8 is software (libvpx) everywhere and is what
  /// negotiation picks anyway; H.265/AV1 payload types kill the iOS
  /// answerer, and even H264/VP9 entries make iOS's FIRST call fail
  /// applying its own answer while its hardware codec path is cold ("Failed
  /// to set local video description recv parameters" — first call black,
  /// later calls fine). Also covers the older macOS issue (Apple H.264 hw
  /// profile not decoding on Windows libwebrtc).
  Future<void> _preferVp8ForVideoTrackOnPc(
      RTCPeerConnection pc, String trackId) async {
    try {
      final caps = await getRtpSenderCapabilities('video');
      final all = caps.codecs ?? const <RTCRtpCodecCapability>[];
      bool mimeIs(RTCRtpCodecCapability c, String name) =>
          c.mimeType.toLowerCase() == 'video/$name';
      final safe = [
        ...all.where((c) => mimeIs(c, 'vp8')),
        ...all.where(
            (c) => mimeIs(c, 'rtx') || mimeIs(c, 'red') || mimeIs(c, 'ulpfec')),
      ];
      if (safe.isEmpty) return;
      final transceivers = await pc.getTransceivers();
      for (final t in transceivers) {
        if (t.sender.track?.id == trackId) {
          await t.setCodecPreferences(safe);
          _vcLog('[HOLLOW-VC] Constrained camera codecs for track $trackId '
              '(${safe.length}/${all.length} kept)');
          return;
        }
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] _preferVp8ForVideoTrackOnPc failed: $e');
    }
  }
}

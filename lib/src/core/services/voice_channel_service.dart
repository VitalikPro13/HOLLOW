import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/services/frame_cryptor_service.dart';
import 'package:hollow/src/core/services/gossip_forward.dart';
import 'package:hollow/src/core/services/ice_repair.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/services/ice_route_probe.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/core/services/link_watchdog.dart';
import 'package:hollow/src/core/services/video_quality_ladder.dart';
import 'package:hollow/src/core/services/remote_track_volume.dart';
import 'package:hollow/src/core/services/local_meter_loopback.dart';
import 'package:hollow/src/core/services/local_speaking_detector.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

void _vcLog(String msg) {
  network_api.logFromDart(message: msg);
}

/// Manages WebRTC peer connections for voice channel mesh audio.
///
/// One RTCPeerConnection per participant, over a single shared capture. SDP
/// and ICE ride MLS-encrypted targeted messages.
class VoiceChannelService {
  static const int maxVoicePcs = 15;

  final String localPeerId;
  Map<String, dynamic> iceServers;

  final Map<String, RTCPeerConnection> _peerConnections = {};

  /// Pending ICE candidates per peer (received before remote description set).
  final Map<String, List<RTCIceCandidate>> _pendingCandidates = {};

  final Map<String, bool> _remoteDescSet = {};

  /// Guards concurrent connectToPeer calls for the same peer. The join
  /// announcement arrives TWICE by design (MLS broadcast plus plaintext
  /// member fan) and `_peerConnections[peerId]` is only set after the native
  /// createPeerConnection await, so without this reservation the duplicate
  /// event tears the first PC down mid-negotiation and leaves the offerer
  /// paired with a stale answer: a dead mic until the next renegotiation.
  final Set<String> _connecting = {};

  /// Shared local audio stream (captured once, added to all PCs).
  MediaStream? _localAudioStream;
  bool _isMuted = false;

  String? _serverId;
  String? _channelId;

  /// Audio quality settings (default: voice preset).
  int opusBitrate = 96000;
  bool opusStereo = false;

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

  /// AI noise suppression preference; see the twin fields in voice_service.
  bool noiseSuppressAi = false;

  /// Which engine: RNNoise by default, or DFN3.
  int noiseSuppressEngine = Helper.nsEngineRnnoise;

  /// TRUE when DFN cannot run here and WebRTC's legacy NS was re-enabled in
  /// the capture constraints as the fallback.
  bool _dfnFallbackNsOn = false;

  /// WebRTC's own NS is wanted whenever DFN isn't (or can't be) doing the job.
  bool get _wantWebrtcNs => !noiseSuppressAi || _dfnFallbackNsOn;

  /// VAD: set of currently speaking peer IDs (updated every 200ms).
  final Set<String> _speakingPeers = {};
  Timer? _vadTimer;
  /// Previous totalAudioEnergy per peer for delta calculation.
  final Map<String, double> _prevEnergy = {};

  /// Are WE talking? Kept OUT of [_speakingPeers] deliberately: that set is
  /// keyed by routable device ids while the UI holds master ids, so "are we
  /// in the set" was never a reliable question.
  bool _localSpeaking = false;

  /// Callback when speaking state changes: the REMOTE peers currently
  /// speaking, and whether WE are.
  void Function(Set<String> speakingPeers, bool localSpeaking)?
      onSpeakingChanged;

  /// Voice levels 0..1 on every poll: remote peers by DEVICE id from
  /// inbound-rtp, ours from the capture meter. Empty and 0 once it stops.
  void Function(Map<String, double> remote, double local)? onLevels;

  /// Remote levels read by the current poll, by peer.
  final Map<String, double> _remoteLevels = {};

  /// The level poll's period; [setPollInterval] changes it mid-call.
  Duration pollInterval = kVoicePollNormal;

  /// Gossip mode: if true, only connect to gossipNeighbors (not all participants).
  bool get gossipMode => _gossipMode;
  set gossipMode(bool on) {
    _gossipMode = on;
    _scheduleWants();
    unawaited(_forwardGossipSources());
  }

  bool _gossipMode = false;

  Set<String> get gossipNeighbors => _gossipNeighbors;
  set gossipNeighbors(Set<String> ids) {
    _gossipNeighbors = ids;
    _scheduleWants();
  }

  Set<String> _gossipNeighbors = {};

  /// Everyone in our voice channel, ourselves excluded; the provider owns it.
  Set<String> Function()? channelMembers;

  /// Gossip: the origins each leg asked us to forward to it.
  final Map<String, Set<String>> _fwdWanted = {};

  /// Gossip: the origins we last asked each leg to forward to us.
  final Map<String, Set<String>> _wantSent = {};

  Timer? _wantsTimer;

  /// Gossip: each neighbour we hold no live leg to, since when, and when we
  /// next reach for its leg.
  final Map<String, ({DateTime since, DateTime reachAt, int reaches})>
      _legAwaited = {};
  Timer? _legGraceTimer;

  late final ForwardRenegBatcher _fwdReneg =
      ForwardRenegBatcher(_renegotiateForwards);

  /// Serialises forward changes: two at once would add one track twice.
  Future<void> _fwdSync = Future<void>.value();

  /// Gossip: the voices we hear straight from their speaker, by origin; each
  /// goes, under SFrame only, to the legs that asked for it.
  final Map<String, (MediaStreamTrack, MediaStream)> _gossipSources = {};

  /// Gossip: the forwarded senders on each neighbour's leg, by track id.
  final Map<String, Map<String, ({String origin, RTCRtpSender sender})>>
      _fwdOut = {};

  /// Gossip: the forwarded voices on each forwarder's leg, track id to
  /// origin, as its SDP declares them.
  final Map<String, Map<String, String>> _fwdIn = {};

  /// Forwarded copies kept silent, by forwarder: their origin is heard
  /// directly or through an earlier copy. Keyed per leg, since a track id is
  /// whatever the sending peer writes and another leg may carry the same one.
  final Map<String, Set<String>> _fwdSilent = {};

  /// Whether [sender] carries a voice we forward for someone else.
  bool _isFwdSender(String peerId, RTCRtpSender sender) =>
      _fwdOut[peerId]?.containsKey(sender.track?.id) ?? false;

  /// Whether [receiver] carries a voice [peerId] forwards for someone else.
  bool _isFwdReceiver(String peerId, RTCRtpReceiver receiver) =>
      _fwdIn[peerId]?.containsKey(receiver.track?.id) ?? false;

  /// Whether a voice [forwarder] names a forward of [origin] is taken as one:
  /// only with forwarding on, for a member we asked THAT leg for and still
  /// hear on no leg of our own. Anything else is the forwarder's own voice, so
  /// a peer cannot slip its microphone past our volume, the speaking light or
  /// the silence we keep for a member heard directly.
  bool _acceptsForward(String forwarder, String origin) =>
      gossipForwardingEnabled &&
      origin != localPeerId &&
      origin != forwarder &&
      (_wantSent[forwarder]?.contains(origin) ?? false) &&
      !_linkWatch.containsKey(origin);

  /// The forwards [sdp] from [peerId] declares that we take as forwards.
  Map<String, String> _forwardsIn(String peerId, String sdp) => {
        for (final e in forwardedTracksIn(sdp).entries)
          if (_acceptsForward(peerId, e.value)) e.key: e.value,
      };

  /// What [sdp] must say before it goes to [peerId]: forwarded tracks under
  /// their origin's stream id. The SDP names a sender by its sender id, which
  /// is the track id only for a fresh transceiver: a forwarder without a mic
  /// sends on its leg's audio section, which keeps its own id.
  String _forPeer(String peerId, String sdp) => markForwardedTracks(sdp, {
        for (final e in (_fwdOut[peerId] ?? const {}).entries) ...{
          e.key: e.value.origin,
          e.value.sender.senderId: e.value.origin,
        },
      });

  FrameCryptorService? frameCryptor;

  /// SFrame heal hook, fired on every cryptor state transition with the
  /// participant collapsed to the mesh peerId ('screen:X' becomes X). The
  /// provider runs the heal ladder off sustained failure states.
  void Function(String peerId, String kind, bool isReceiver,
      FrameCryptorState state)? onSframeCryptorState;

  // Camera (video) support

  /// Shared local camera stream (captured once, added to all PCs).
  MediaStream? _localVideoStream;
  bool _isCameraOn = false;
  /// Serializes startCamera/stopCamera so a rapid stop then start cannot open
  /// a new V4L2 capturer while the old one is still tearing down; libwebrtc's
  /// RaceChecker aborts on /dev/video0.
  Future<void> _cameraLock = Future<void>.value();
  bool _useFrontCamera = true;

  final Map<String, RTCVideoRenderer> _remoteVideoRenderers = {};

  final Map<String, MediaStream> _remoteVideoStreams = {};

  /// Which remote video streams are synthetic (Dart-owned). Streams from
  /// onTrack belong to libwebrtc and must NOT be disposed from Dart; only
  /// ones we created via createLocalMediaStream are safe to dispose.
  final Map<String, bool> _remoteVideoStreamSynthetic = {};

  /// Callback when a remote peer's video track arrives or is removed.
  void Function(String peerId, RTCVideoRenderer? renderer)? onRemoteVideoChanged;

  /// Fired when a peer's audio connection reaches connected/stable, so the
  /// provider can send screen share offers.
  void Function(String peerId)? onPeerConnected;

  /// One hold-open watchdog per peer leg, created when that leg first
  /// connects. The mesh used to close a peer outright on `failed` with no
  /// recovery attempt, so a member whose Wi-Fi hiccuped dropped out of the
  /// channel. Per peer, not per channel: one member on hotel Wi-Fi is that
  /// member's problem and must not cost anyone else their audio or picture.
  final Map<String, LinkWatchdog> _linkWatch = {};

  /// Peers we are deliberately tearing down. `closePeer` calls `pc.close()`,
  /// which reports `closed` straight back into the state handler, where the
  /// watchdog would read it as the remote end going away.
  final Set<String> _closingPeers = {};

  /// When a rebuild of this peer's leg last began, on EITHER side.
  ///
  /// Both ends watch the same leg and both can decide it is broken seconds
  /// apart: without a window the second one tears down what the first just
  /// rebuilt, and neither dials again. Claimed when we rebuild, when we ask
  /// the peer to, and when we accept a rebuild offer of theirs.
  final Map<String, DateTime> _legRebuiltAt = {};

  /// How long one rebuild owns the recovery of a leg. Comfortably longer than
  /// a PC bring-up, which is what a rebuild is.
  static const _legRebuildWindow = Duration(seconds: 10);

  /// How long a gossip neighbour's leg may take to come up before we ask a
  /// forwarder for its voice and reach for the leg again.
  @visibleForTesting
  Duration legSetupGrace = const Duration(seconds: 10);

  /// Slow retries for legs whose whole hold-open window was spent.
  ///
  /// A DM call that gives up hangs up and can be redialed. A voice channel
  /// has no such moment: the member is still in the roster, so a leg
  /// abandoned here would be silent forever.
  final Map<String, Timer> _legRedial = {};

  /// Whether [peerId] is still in the voice channel we are in. Injected by the
  /// provider, which owns the participant sets; null means "assume yes".
  bool Function(String peerId)? isChannelParticipant;

  /// Deafen and per-peer volumes live on the RECEIVER, so a rebuilt leg
  /// arrives with a brand new receiver at full volume. Held here so
  /// [_restorePeerAudioState] can put them back.
  bool _isDeafened = false;
  final Map<String, double> _peerVolumes = {};

  /// Publish a peer leg's health for the UI.
  void Function(String peerId, LinkHealthSnapshot snapshot)? onLinkHealth;

  /// A leg spent its whole hold-open window without connecting.
  void Function(String peerId)? onLegGiveUp;

  /// Whether our relay link can carry a renegotiation offer right now,
  /// injected so the service never reaches into Riverpod.
  bool Function()? canSignal;

  /// Peers that need camera renegotiation once their PC reaches stable state.
  final Set<String> _pendingCameraReneg = {};

  bool get isCameraOn => _isCameraOn;

  /// Local camera stream (for local renderer in provider).
  MediaStream? get localVideoStream => _localVideoStream;

  VoiceChannelService({
    required this.localPeerId,
    required this.iceServers,
    @visibleForTesting AloneMeterKeeper<MediaStream, Object>? aloneMeter,
  }) : _aloneMeter = aloneMeter ?? _newAloneMeter();

  bool get isActive => _serverId != null;

  int get peerCount => _peerConnections.length;

  /// Set of peer IDs we currently have audio PCs with.
  Set<String> get connectedPeerIds => _peerConnections.keys.toSet();

  /// The live audio-mesh PC to [peerId], if any. Read-only: `watchScreenShare`
  /// probes it for the viewer's route hint, and must never store or close
  /// through this.
  RTCPeerConnection? pcFor(String peerId) => _peerConnections[peerId];

  // Lifecycle

  Future<void> startAudio(String serverId, String channelId) async {
    _serverId = serverId;
    _channelId = channelId;
    _aloneMeterOff = false;
    // Keeps a pending completer: a leg built before this call already waits
    // on it (the peer's offer can beat our own join here).
    final micSettled = _localAudioSettled.isCompleted
        ? (_localAudioSettled = Completer<void>())
        : _localAudioSettled;

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

    // Kick the DFN3 engine and decide the WebRTC-NS fallback BEFORE building
    // constraints (see the matching note in voice_service.dart).
    await _syncNoiseSuppressAiEngine();
    final audioConstraints = <String, dynamic>{
      'echoCancellation': true,
      // Legacy NS off while DFN3 owns suppression (unless fallback re-armed).
      'noiseSuppression': _wantWebrtcNs,
      'googNoiseSuppression': _wantWebrtcNs,
      // AGC OFF, see the matching note in voice_service.dart: WebRTC's AGC
      // was fighting our enhancement chain with a conservative -18 dBFS
      // target, leaving the mic quiet. We own loudness in the post-APM
      // chain; AEC and NS stay on. project_voice_agc_loudness_rvox.
      'autoGainControl': false,
      'googAutoGainControl': false,
    };
    if (preferredAudioInputDeviceId != null) {
      audioConstraints['optional'] = [
        {'sourceId': preferredAudioInputDeviceId}
      ];
      _vcLog('[HOLLOW-VC] Requesting input device: $preferredAudioInputDeviceId');
    }

    // Listening for the overlay gives the mic back before the call opens it.
    // Legs built meanwhile already wait on [micSettled], which completes only
    // once our own getUserMedia below has settled; a failed handover must
    // not leave it pending.
    try {
      await overlayMic.yieldToCall(OverlayMicHold.voiceChannel);
    } catch (e) {
      _vcLog('[HOLLOW-VC] Overlay listening handover failed: $e');
    }

    try {
      _localAudioStream = await navigator.mediaDevices.getUserMedia({
        'audio': audioConstraints,
        'video': false,
      });
      _capturedAudioInputDeviceId = preferredAudioInputDeviceId;
      final tracks = _localAudioStream!.getAudioTracks();
      _vcLog('[HOLLOW-VC] Got local audio, tracks=${tracks.length}');
      // A join muted before the mic opened starts with its track off.
      if (_isMuted) {
        for (final track in tracks) {
          track.enabled = false;
        }
      }

      // Mic gain rides the native post-APM capture processor (makeup gain
      // plus a -3 dBFS limiter). Process-global, so always set it; at 1.0 it
      // is transparent. NOT setVolume(), which only scales remote tracks.
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

      // Do NOT bypass Apple's Voice-Processing IO: it kills Apple's hardware
      // AEC, giving echo everywhere and a persistent feedback howl on the
      // loudspeaker route. See voice_service._captureLocalAudio.
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to capture audio: $e');
      // Proceed without audio — user can still hear others.
    }
    if (!micSettled.isCompleted) micSettled.complete();

    if (preferredAudioOutputDeviceId != null) {
      try {
        await Helper.selectAudioOutput(preferredAudioOutputDeviceId!);
      } catch (_) {}
    }

    _startVadTimer();
    unawaited(_reconcileAloneMeter());
  }

  /// Completes once [startAudio] holds its microphone or gave up on it.
  Completer<void> _localAudioSettled = Completer<void>();

  /// A leg built before the microphone is open carries no sender, so our
  /// voice never reaches that peer and our capture never runs (a joiner's
  /// answer can beat its own getUserMedia). Waits AFTER the leg exists, so
  /// its early ICE candidates queue on it.
  /// Bounded: a capture stuck behind an OS prompt must not hold the leg.
  Future<bool> _awaitLocalAudio(String peerId, RTCPeerConnection pc) async {
    final settled = _localAudioSettled;
    if (!settled.isCompleted) {
      await settled.future
          .timeout(const Duration(seconds: 5), onTimeout: () {});
    }
    return identical(_peerConnections[peerId], pc);
  }

  /// Initiate WebRTC connection to a peer who is already in the channel.
  /// Only call this if localPeerId < peerId (glare prevention).
  Future<void> connectToPeer(String peerId) async {
    if (_serverId == null || _channelId == null) return;

    _vcLog('[HOLLOW-VC] Creating offer for peer $peerId');
    final pc = await _createPeerConnection(peerId);
    try {
      if (!await _awaitLocalAudio(peerId, pc)) return;
      _addLocalAudioTracks(pc);

      await _enableSframeSender(peerId, pc);

      final offer = await pc.createOffer();
      final mungedSdp = _mungeOpusParams(offer.sdp!);
      await pc.setLocalDescription(
          RTCSessionDescription(mungedSdp, offer.type));

      final payload = jsonEncode({'sdp': _forPeer(peerId, mungedSdp)});
      await network_api.voiceChannelSendSignal(
        serverId: _serverId!,
        channelId: _channelId!,
        peerId: peerId,
        signalType: 'sdp_offer',
        payload: payload,
      );
    } catch (e) {
      // A throw here leaves a live PC (already in _peerConnections)
      // stranded; dispose it so its libwebrtc thread-set cannot leak.
      _vcLog('[HOLLOW-VC] connectToPeer($peerId) failed, closing PC: $e');
      await closePeer(peerId);
      rethrow;
    }
  }

  // Signal handling

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
      case 'fwd_want':
        _onForwardWant(peerId, payload);
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
      if (!await _awaitLocalAudio(peerId, pc)) return;
      _addLocalAudioTracks(pc);

      await _enableSframeSender(peerId, pc);

      _fwdIn[peerId] = _forwardsIn(peerId, sdp);
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescSet[peerId] = true;
      await _flushPendingCandidates(peerId);

      final answer = await pc.createAnswer();
      final mungedSdp = _mungeOpusParams(answer.sdp!);
      await pc.setLocalDescription(
          RTCSessionDescription(mungedSdp, answer.type));

      final answerPayload = jsonEncode({'sdp': _forPeer(peerId, mungedSdp)});
      await network_api.voiceChannelSendSignal(
        serverId: serverId,
        channelId: channelId,
        peerId: peerId,
        signalType: 'sdp_answer',
        payload: answerPayload,
      );

      // With the camera on, renegotiate to add the video track now that the
      // initial audio connection is established.
      _pendingCameraReneg.remove(peerId);
      if (_isCameraOn && _localVideoStream != null) {
        _vcLog('[HOLLOW-VC] Camera on — sending renegotiation to add video for $peerId (answerer)');
        _addLocalVideoTracks(pc);
        await _enableSframeSenderVideo(peerId, pc);
        await _sendRenegotiationOffer(peerId);
      }
    } catch (e) {
      // setRemoteDescription on an unsupported-codec SDP is a classic throw
      // point; dispose the stranded PC before propagating.
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

    // A stable PC has no pending local offer, and applying an answer would
    // throw "Called in wrong state: stable" for a duplicate or late one.
    // Skip it rather than surface a platform error through the zone handler.
    if (pc.signalingState == RTCSignalingState.RTCSignalingStateStable) {
      _vcLog('[HOLLOW-VC] Ignoring SDP answer from $peerId — PC already stable');
      return;
    }

    _vcLog('[HOLLOW-VC] Received SDP answer from $peerId');
    _fwdIn[peerId] = _forwardsIn(peerId, sdp);
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    _remoteDescSet[peerId] = true;
    await _flushPendingCandidates(peerId);

      // With the camera on, renegotiate to add the video track now that the
      // initial audio connection is established.
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
      // Cap pending ICE candidates per peer.
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

  // Peer management

  /// Called when a remote peer joins our voice channel.
  /// Determines who should create the offer (glare prevention).
  Future<void> onPeerJoinedMyChannel(String peerId) async {
    // BELT: never dial ourselves. A self id reaching here is an upstream
    // participant-set bug, and the dial can only mint dead PCs and "No
    // session" storms.
    if (peerId == localPeerId) {
      _vcLog('[HOLLOW-VC] Ignoring self id in participant dial: $peerId');
      return;
    }
    _scheduleWants();
    // In gossip mode, only connect to gossip neighbors.
    if (gossipMode && !gossipNeighbors.contains(peerId)) {
      return; // Not a gossip neighbor — skip (audio forwarded via neighbors).
    }
    // Already connected or mid-connect: the join announcement arrives twice
    // by design (MLS broadcast plus plaintext fan; see _connecting).
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

  Future<void> closePeer(String peerId) async {
    _closingPeers.add(peerId);
    _linkWatch.remove(peerId)?.stop();
    // Whatever was last said about this leg is moot now, and a leg torn down
    // AFTER its watchdog was already gone has nothing left to retract it.
    // Callers that mean to keep a flair up republish it straight after.
    onLinkHealth?.call(peerId, const LinkHealthSnapshot());
    final pc = _peerConnections.remove(peerId);
    if (pc != null) {
      unawaited(_reconcileAloneMeter());
      _vcLog('[HOLLOW-VC] Closing connection to $peerId');
      await pc.close();
      await pc.dispose();
    }
    _closingPeers.remove(peerId);
    _pendingCandidates.remove(peerId);
    _remoteDescSet.remove(peerId);
    _pendingCameraReneg.remove(peerId);

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

    _prevEnergy.remove('in-$peerId');
    _fwdOut.remove(peerId);
    _fwdIn.remove(peerId);
    _fwdSilent.remove(peerId);
    _fwdWanted.remove(peerId);
    _wantSent.remove(peerId);
    _fwdReneg.cancel(peerId);
    await frameCryptor?.disableForPeer(peerId);
    _gossipSources.remove(peerId);
    await _forwardGossipSources();
    _scheduleWants();
  }

  /// Enable SFrame sender encryption on outgoing audio tracks for a peer.
  Future<void> _enableSframeSender(String peerId, RTCPeerConnection pc) async {
    if (frameCryptor == null || !frameCryptor!.isEnabled) {
      return;
    }
    try {
      final senders = await pc.getSenders();
      for (final sender in senders) {
        if (sender.track?.kind == 'audio' && !_isFwdSender(peerId, sender)) {
          await frameCryptor!.enableForSender(peerId, sender);
          break;
        }
      }
      await frameCryptor!.setKeyIndexForPeer(peerId, frameCryptor!.currentKeyIndex);
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to enable SFrame sender: $e');
    }
  }

  /// (Re)binds the SFrame receiver cryptor to the CURRENT inbound audio
  /// receiver for [peerId]. enableForReceiver is idempotent per (peer, kind),
  /// so the old cryptor is dropped first; required after the remote side
  /// swaps its mic mid-call. Skipped before the key lands, where the
  /// key-apply path binds receivers itself.
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
          if (r.track?.kind == 'audio' && !_isFwdReceiver(peerId, r)) {
            target = r;
          }
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
      // NEWEST audio receiver wins: mid-call mic switches leave dead
      // transceivers earlier in the list.
      RTCRtpReceiver? target;
      for (final receiver in receivers) {
        if (receiver.track?.kind == 'audio' &&
            !_isFwdReceiver(peerId, receiver)) {
          target = receiver;
        }
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

  Future<void> _handleRemoteVideoTrack(
    String peerId,
    RTCTrackEvent event,
    RTCPeerConnection pc,
  ) async {
    _vcLog('[HOLLOW-VC] Received video track from $peerId');

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

    final renderer = RTCVideoRenderer();
    await renderer.initialize();

    // The peer may have LEFT while we awaited initialize(): closePeer would
    // already have cleared this peer's maps, so storing a renderer now would
    // orphan it. Dispose what we just built and bail.
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

    await _enableSframeReceiverVideo(peerId, pc);

    // Notify provider after a short delay (renderer needs a frame to display).
    await Future.delayed(const Duration(milliseconds: 100));
    onRemoteVideoChanged?.call(peerId, renderer);
  }

  /// Sets the SFrame key and enables encryption on all existing PCs, when
  /// the MLS epoch key arrives or changes.
  Future<void> setSframeKey(int epoch, Uint8List key) async {
    if (frameCryptor == null) return;
    await frameCryptor!.rotateKey(epoch % 16, key); // sets key + updates all cryptor indices
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
      await _bindForwardedReceivers(peerId, pc);
    }
    await _forwardGossipSources();
    _vcLog('[HOLLOW-VC] SFrame key set for epoch $epoch, enabled on ${_peerConnections.length} PCs');
  }

  /// Heal step 1: drop + re-enable [peerId]'s receiver cryptors (audio, and
  /// video when a renderer exists) and re-assert the key index. Fixes cryptors
  /// wedged on a dead transceiver or a stale index without touching the PC.
  Future<void> rebindReceiversFor(String peerId) async {
    final pc = _peerConnections[peerId];
    if (pc == null || frameCryptor == null) return;
    await _rebindSframeReceiver(peerId, pc, null);
    await _bindForwardedReceivers(peerId, pc, fresh: true);
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
    // Before the mic stream is stopped below: the loopback sends its track.
    _aloneMeterOff = true;
    await _aloneMeter.shutdown();
    if (!_localAudioSettled.isCompleted) _localAudioSettled.complete();
    _localAudioSettled = Completer<void>();
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
    _gossipSources.clear();
    _fwdOut.clear();
    _fwdIn.clear();
    _fwdSilent.clear();
    _fwdWanted.clear();
    _wantSent.clear();
    _wantsTimer?.cancel();
    _legGraceTimer?.cancel();
    _legAwaited.clear();
    _fwdReneg.cancelAll();
    _pendingCameraReneg.clear();
    _gossipMode = false;
    _gossipNeighbors = {};
    await frameCryptor?.dispose();
    frameCryptor = null;
  }

  // ---------------------------------------------------------------
  //  Audio controls
  // ---------------------------------------------------------------

  void setMuted(bool muted) {
    // Tell the capture processor first (process-global, harmless without a
    // stream): the dynamic servo FREEZES while muted so it cannot adapt to
    // room bleed and bury the voice on unmute, since the APM keeps
    // processing real mic input while the track is disabled.
    Helper.setCaptureMuted(muted).catchError((_) {});
    // Kept before the mic opens too, so a muted join never records.
    _isMuted = muted;
    unawaited(_reconcileAloneMeter());
    if (_localAudioStream == null) {
      _vcLog('[HOLLOW-VC] setMuted($muted) recorded, no local stream yet');
      return;
    }
    for (final track in _localAudioStream!.getAudioTracks()) {
      track.enabled = !_isMuted;
    }
    _vcLog('[HOLLOW-VC] setMuted($muted) applied to '
        '${_localAudioStream!.getAudioTracks().length} track(s)');
  }

  /// Mutes or unmutes all incoming remote audio (deafen).
  ///
  /// Every peer is handled independently: in a mesh, one connection that
  /// cannot be silenced (a closing PC) must not abandon the peers after it,
  /// leaving some voices playing while others go quiet.
  Future<void> setDeafened(bool deafened) async {
    _isDeafened = deafened;
    for (final entry in _peerConnections.entries.toList()) {
      // Un-deafening restores the volume the user chose for THAT member, not
      // a flat 1.0: a peer they had turned down would come back at full
      // volume, which reads as the slider forgetting itself.
      final volume = deafened ? 0.0 : (_peerVolumes[entry.key] ?? 1.0);
      try {
        final receivers = await entry.value.getReceivers();
        var found = 0, applied = 0;
        for (final r in receivers) {
          if (r.track?.kind == 'audio') {
            final silent =
                _fwdSilent[entry.key]?.contains(r.track!.id) ?? false;
            found++;
            if (await setRemoteReceiverVolume(silent ? 0.0 : volume, r)) {
              applied++;
            }
          }
        }
        _vcLog('[HOLLOW-VC] Volume ${volume.toStringAsFixed(2)} (deafen '
            '$deafened) on $applied/$found receiver(s) of ${entry.key}');
      } catch (e) {
        _vcLog('[HOLLOW-VC] Deafen skipped for ${entry.key}: $e');
      }
    }
  }

  Future<void> updateMicGain(double gain) async {
    micGain = gain;
    // Live mid-session update, process-global and atomic, so it works
    // without a local stream too.
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

  /// Toggles AI noise suppression live. In a session it re-captures the mic,
  /// and the mesh swap plus renegotiation happen internally, unlike the DM
  /// service's caller contract.
  Future<void> updateNoiseSuppressAi(bool enabled) async {
    noiseSuppressAi = enabled;
    _dfnFallbackNsOn = false;
    await _syncNoiseSuppressAiEngine();
    _vcLog('[HOLLOW-VC] Updated AI noise suppression: $enabled');
    if (_localAudioStream == null) return;
    await _recaptureMic(_capturedAudioInputDeviceId);
  }

  /// Switches the AI-NS engine. Native swaps the engine handle in place,
  /// with no constraint flip, re-capture or mesh reneg, so it is safe
  /// mid-session. Behaviour-identical to voice_service.
  Future<void> updateNoiseSuppressEngine(int engine) async {
    noiseSuppressEngine = engine;
    if (!noiseSuppressAi) return;
    _dfnFallbackNsOn = false;
    await _syncNoiseSuppressAiEngine();
    _vcLog('[HOLLOW-VC] Updated AI-NS engine: $engine');
  }

  /// Post-enable safety net: if the engine reports it cannot run here while
  /// legacy NS is off, re-arm WebRTC NS and re-capture. See
  /// voice_service.reconcileNoiseSuppressAi.
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

  /// Pushes the AI-NS preference into the native engine and refreshes the
  /// fallback decision from its latched status flags.
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

  /// Records how loud [peerId] is heard; while deafened it is only recorded,
  /// and un-deafening applies it.
  Future<void> setRemoteVolume(String peerId, double volume) async {
    _peerVolumes[peerId] = volume;
    if (_isDeafened) return;
    await _applyRemoteVolume(peerId, volume);
  }

  /// The volume [peerId]'s own voices play at right now.
  double _wantedVolume(String peerId) =>
      _isDeafened ? 0.0 : (_peerVolumes[peerId] ?? 1.0);

  /// Applies a playback volume WITHOUT recording it as the user's choice:
  /// the deafen restore passes 0.0 through here, and remembering that would
  /// erase the per-peer volume it is meant to protect. Covers EVERY audio
  /// receiver of the leg but forwards: the peer decides how many it opens.
  Future<void> _applyRemoteVolume(String peerId, double volume) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;
    final receivers = await pc.getReceivers();
    var found = 0, applied = 0;
    for (final r in receivers) {
      if (r.track?.kind == 'audio' && !_isFwdReceiver(peerId, r)) {
        found++;
        if (await setRemoteReceiverVolume(volume, r)) applied++;
      }
    }
    _vcLog('[HOLLOW-VC] Volume ${volume.toStringAsFixed(2)} on '
        '$applied/$found receiver(s) of $peerId');
  }

  /// Track ids of every connected peer's inbound audio, used by the Windows
  /// entire-screen anti-echo path to redirect them to an out-of-process
  /// renderer so they are not re-captured.
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

  // Camera (video) controls

  /// Starts capturing the camera and adds the video track to all existing
  /// PCs, returning the local stream for the provider's renderer. Serialized
  /// against stopCamera (shared [_cameraLock]) so a stop then start cannot
  /// race two V4L2 capturers on the same device.
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

    // LINUX: with the device still open from an earlier startCamera this
    // session (stopCamera keeps it open to avoid the V4L2 reopen race),
    // resume the existing track instead of reopening /dev/video*.
    if (Platform.isLinux && _localVideoStream != null) {
      await _resumeLinuxCameraTrack();
    }

    if (_localVideoStream == null) {
      if (!await _captureCameraStream()) return null;
    }

    final videoTrack = _localVideoStream?.getVideoTracks().firstOrNull;
    if (videoTrack == null) return null;

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

  /// Captures the camera into [_localVideoStream] for [_startCameraInner].
  /// False when getUserMedia fails, leaving the camera off.
  Future<bool> _captureCameraStream() async {
    try {
      final videoConstraints = <String, dynamic>{
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 30},
      };
      // flutter_webrtc native uses 'sourceId' in the optional array;
      // 'deviceId' is ignored by GetUserVideo().
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
      if (_localVideoStream!.getVideoTracks().isEmpty) {
        final emptyStream = _localVideoStream!;
        _localVideoStream = null;
        _isCameraOn = false;
        await emptyStream.dispose();
        _vcLog('[HOLLOW-VC] Camera capture returned no video track');
        return false;
      }
      _capturedCameraDeviceId = preferredCameraDeviceId;
      _isCameraOn = true;
      _vcLog('[HOLLOW-VC] Camera started, tracks=${_localVideoStream!.getVideoTracks().length}');
      return true;
    } catch (e) {
      _vcLog('[HOLLOW-VC] Failed to capture camera: $e');
      return false;
    }
  }

  /// Adds the freshly enabled camera track to every mesh PC and renegotiates
  /// the stable ones; the rest queue via [_pendingCameraReneg].
  Future<void> _addCameraTrackToPeers(MediaStreamTrack videoTrack) async {
    for (final entry in _peerConnections.entries.toList()) {
      final peerId = entry.key;
      final pc = entry.value;

      final sigState = pc.signalingState;
      if (sigState != RTCSignalingState.RTCSignalingStateStable) {
        _vcLog('[HOLLOW-VC] Skipping camera reneg for $peerId — state: $sigState (will reneg after stable)');
        _pendingCameraReneg.add(peerId);
        continue;
      }

      await pc.addTrack(videoTrack, _localVideoStream!);

      // Constrain the offer to universal codecs (VP8 first): desktop builds
      // otherwise advertise H.265/AV1 payload types that break the iOS
      // answerer, and Apple's H.264 profile does not decode on Windows.
      if (videoTrack.id != null) {
        await _preferVp8ForVideoTrackOnPc(pc, videoTrack.id!);
      }

      await _enableSframeSenderVideo(peerId, pc);

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

    await _removeVideoSendersFromPeers();

    // Stop and dispose the camera stream, EXCEPT on Linux, where closing the
    // V4L2 device and reopening it on the next startCamera races the
    // libwebrtc CaptureThread and ABORTS the process. There the device stays
    // open with the track paused for the whole session and is released once
    // in closeAll(), where nothing reopens after.
    await _releaseOrPauseCameraStream();

    // LINUX V4L2 RACE: StopCapture() does not join its CaptureThread, so
    // dispose() returns while the OS thread still holds /dev/video0. Settle
    // here, inside the _cameraLock critical section, so the next
    // startCamera cannot reopen the device mid-teardown.
    if (Platform.isLinux) {
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  /// Removes every PC's video sender and renegotiates the stable ones, the
  /// camera-off half of the addTrack/removeTrack cycle.
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
        final sigState = pc.signalingState;
        if (sigState == RTCSignalingState.RTCSignalingStateStable) {
          await _sendRenegotiationOffer(peerId);
        }
      } catch (e) {
        _vcLog('[HOLLOW-VC] Error removing video sender for $peerId: $e');
      }
    }
  }

  /// Camera-off stream teardown: a full stop and dispose everywhere except
  /// Linux, where the V4L2 device stays open with the track paused.
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

  /// Local camera facing (true = front); the UI mirrors only the front
  /// preview.
  bool get useFrontCamera => _useFrontCamera;

  /// Switches front/back camera and returns the new facing from the NATIVE
  /// side: with more than two cameras a blind toggle drifts out of sync.
  Future<bool> switchCamera() async {
    if (!_isCameraOn || _localVideoStream == null) return _useFrontCamera;
    final videoTracks = _localVideoStream!.getVideoTracks();
    if (videoTracks.isEmpty) return _useFrontCamera;
    _useFrontCamera = await Helper.switchCamera(videoTracks.first);
    _vcLog('[HOLLOW-VC] Camera switched, front=$_useFrontCamera');
    return _useFrontCamera;
  }

  // Live device switching (Settings picker changed mid-session)

  /// Device id the live audio stream was captured from; dedup guard against
  /// duplicate provider listeners firing the same switch twice.
  String? _capturedAudioInputDeviceId;
  /// Device id the live camera stream was actually captured from.
  String? _capturedCameraDeviceId;

  /// Live mid-session microphone switch across the whole mesh: captures a
  /// fresh stream, swaps every PC's audio sender via removeTrack + addTrack
  /// (NEVER replaceTrack, which fails silently on Windows libwebrtc),
  /// re-binds SFrame per peer and renegotiates each stable PC. VAD needs no
  /// attention: it reads whatever track the PCs are currently sending.
  Future<void> setAudioInputDevice(String? deviceId) async {
    preferredAudioInputDeviceId = deviceId;
    if (_localAudioStream == null) return; // next session uses it
    if (_capturedAudioInputDeviceId == deviceId) return; // already live
    await _recaptureMic(deviceId);
  }

  /// Shared live mic re-capture, for a device switch OR an NS-constraint
  /// flip. Swaps every PC in the mesh and renegotiates internally.
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

    await _swapAudioSendersToTrack(newTrack, newStream);
    // Moves the loopback onto the new track before the old one is stopped.
    await _reconcileAloneMeter();

    if (oldStream != null) {
      await _disposeReplacedMicStream(oldStream);
    }

    _vcLog('[HOLLOW-VC] Mic switched live to ${deviceId ?? "default"}');
  }

  /// Captures a replacement mic stream for the live switch. Null on a
  /// getUserMedia failure or a trackless capture, so the old mic keeps going.
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
          if (s.track?.kind == 'audio' && !_isFwdSender(peerId, s)) {
            await pc.removeTrack(s);
            break;
          }
        }
        await pc.addTrack(newTrack, newStream);
          // A fresh sender needs a fresh cryptor: enableForSender is
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

  /// Live mid-session camera device switch. NO-OP on Linux, where the V4L2
  /// device must never be closed mid-session, so the new device applies at
  /// the next camera start. Returns the new stream when a swap happened, so
  /// the provider can rebind its local preview renderer to it.
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

  /// Captures a replacement camera stream for the live switch. Null on a
  /// getUserMedia failure or a trackless capture, so the old camera stays.
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
  /// renegotiate the stable PCs.
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

  // Renegotiation, for adding and removing video tracks

  Future<void> _sendRenegotiationOffer(String peerId,
      {bool iceRestart = false}) async {
    final pc = _peerConnections[peerId];
    if (pc == null || _serverId == null || _channelId == null) return;

    try {
      await _offerVideoAsVp8Only(pc);
      final offer = await pc.createOffer();
      final mungedSdp = _mungeOpusParams(offer.sdp!);
      await pc.setLocalDescription(RTCSessionDescription(mungedSdp, offer.type));

      // `ice_restart` tells the answerer this re-offer carries no media
      // change, so it must not run its camera-track safety net, which would
      // otherwise invent a camera tile for us.
      final payload = jsonEncode(
          {'sdp': _forPeer(peerId, mungedSdp), 'ice_restart': iceRestart});
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
    // transceiver and show a phantom camera tile.
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
    _fwdIn[peerId] = _forwardsIn(peerId, sdp);
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

    final answer = await pc.createAnswer();
    final mungedSdp = _mungeOpusParams(answer.sdp!);
    await pc.setLocalDescription(RTCSessionDescription(mungedSdp, answer.type));

    final answerPayload = jsonEncode({'sdp': _forPeer(peerId, mungedSdp)});
    await network_api.voiceChannelSendSignal(
      serverId: serverId,
      channelId: channelId,
      peerId: peerId,
      signalType: 'reneg_answer',
      payload: answerPayload,
    );

    // After renegotiation, check for a remote video track we have no
    // renderer for: onTrack may not fire when a transceiver is reused. NOT
    // for an ICE restart, where nothing about the media changed and anything
    // found would be a transceiver that was already there and already idle.
    if (!iceRestart) {
      await _checkRemoteVideoTrack(peerId, pc);
    }
  }

  /// Checks for a remote video track on a PC and creates a renderer if
  /// missing, for when onTrack does not fire. Does NOT clean up renderers
  /// when video is gone: they survive camera off/on cycles so the same
  /// stream can resume receiving frames.
  Future<void> _checkRemoteVideoTrack(String peerId, RTCPeerConnection pc) async {
    try {
      final receivers = await pc.getReceivers();
      for (final receiver in receivers) {
        if (receiver.track?.kind == 'video') {
          if (!_remoteVideoRenderers.containsKey(peerId)) {
            _vcLog('[HOLLOW-VC] Found video track without renderer for $peerId — creating');
            final stream = await createLocalMediaStream('video-$peerId');
            try {
              await stream.addTrack(receiver.track!);
            } catch (_) {
              await stream.dispose();
              rethrow;
            }

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
    _fwdIn[peerId] = _forwardsIn(peerId, sdp);
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));

    await _checkPendingCameraReneg(peerId);
  }

  /// Sends the pending camera renegotiation for a peer whose PC just reached
  /// stable state.
  Future<void> _checkPendingCameraReneg(String peerId) async {
    if (!_pendingCameraReneg.remove(peerId)) return;
    if (!_isCameraOn || _localVideoStream == null) return;

    final pc = _peerConnections[peerId];
    if (pc == null) return;

    _vcLog('[HOLLOW-VC] Sending pending camera renegotiation for $peerId');
    final senders = await pc.getSenders();
    final hasVideo = senders.any((s) => s.track?.kind == 'video');
    if (!hasVideo) {
      _addLocalVideoTracks(pc);
    }
    await _enableSframeSenderVideo(peerId, pc);
    await _sendRenegotiationOffer(peerId);
  }

  // Voice activity detection

  void _startVadTimer() {
    _vadTimer?.cancel();
    _vadTimer = Timer.periodic(pollInterval, (_) {
      _pollAudioLevels();
    });
  }

  /// Faster while an OBS page streams; a running poll restarts on the new beat.
  void setPollInterval(Duration interval) {
    if (interval == pollInterval) return;
    pollInterval = interval;
    if (_vadTimer != null) _startVadTimer();
  }

  void _stopVadTimer() {
    _vadTimer?.cancel();
    _vadTimer = null;
    _remoteLevels.clear();
    onLevels?.call(const {}, 0.0);
  }

  /// Hands this poll's levels on. Peers whose leg closed drop out.
  void _emitLevels() {
    if (_vadTimer == null) return;
    _remoteLevels.removeWhere((peer, _) => !_peerConnections.containsKey(peer));
    onLevels?.call(Map.of(_remoteLevels),
        _isMuted ? 0.0 : levelFromDb(_localSpeakingDetector.levelDb));
  }

  /// Our capture runs only while a connected leg carries our microphone
  /// (see [LocalMeterLoopback]); alone, the loopback carries it instead so
  /// the self ring and the stream overlay keep reading our voice. Desktop
  /// only: phones keep their audio session untouched. Muted = mic off: a
  /// muted user alone in a room is not recorded (Vitalik, 2026-10-15).
  final AloneMeterKeeper<MediaStream, Object> _aloneMeter;

  static AloneMeterKeeper<MediaStream, LocalMeterLoopback> _newAloneMeter() =>
      AloneMeterKeeper<MediaStream, LocalMeterLoopback>(
        start: (stream) =>
            LocalMeterLoopback.open(stream.getAudioTracks().first, stream,
                log: _vcLog),
        stop: (loop) => loop.close(),
        log: _vcLog,
      );

  static final bool _meterLoopbackPlatform =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// A leg that reached connected keeps its send stream through a held
  /// `disconnected`, so it still carries our capture.
  bool _legCarriesCapture(RTCPeerConnection pc) {
    final s = pc.connectionState;
    return s == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
        s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;
  }

  bool _aloneMeterOff = true;

  Future<void> _reconcileAloneMeter() {
    if (!_meterLoopbackPlatform) return Future.value();
    final stream = _localAudioStream;
    final hasTrack = stream != null && stream.getAudioTracks().isNotEmpty;
    return _aloneMeter.update(
      source: !_aloneMeterOff && !_isMuted && hasTrack ? stream : null,
      alone: !_peerConnections.values.any(_legCarriesCapture),
    );
  }

  Future<void> _pollAudioLevels() async {
    final newSpeaking = <String>{};

    // LOCAL: the native capture meter, one process-global read; alone in
    // the channel the meter loopback keeps the capture running (see
    // [_aloneMeter]). See [LocalSpeakingDetector] for why not getStats.
    //
    // Reported as its OWN flag rather than as our peer id inside the set,
    // mirroring the 1:1 path: the set is keyed by ROUTABLE device ids and
    // the UI often holds the MASTER id, so a membership test for ourselves
    // silently missed and the self indicator never lit.
    var newLocal = await _localSpeakingDetector.poll(muted: _isMuted);

    // REMOTE: one getStats pass per peer connection. Where the plugin has no
    // capture meter, the same pass also carries the old outgoing-level
    // guess.
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

    if (newLocal != _localSpeaking ||
        !_setEquals(newSpeaking, _speakingPeers)) {
      _localSpeaking = newLocal;
      _speakingPeers
        ..clear()
        ..addAll(newSpeaking);
      onSpeakingChanged?.call(Set.of(_speakingPeers), _localSpeaking);
    }
    _emitLevels();
  }

  /// One-shot diagnostic, twin of the one in `voice_service.dart`. Logged
  /// once per session so a single test run settles whether this platform's
  /// getStats carries an outgoing audio level at all.
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

  /// One getStats pass over [pc]: that peer's inbound audio, plus, when
  /// [wantLocal], our own outgoing level from the same report set.
  ///
  /// Local detection deliberately rides the peer connection instead of a
  /// second mic handle: the old `record` path shells out to `parecord` on
  /// Linux, which PipeWire systems lack, so every Linux user's OWN indicator
  /// stayed dark (issue #37). It also puts voice channels on the same
  /// detector and threshold as 1:1 calls, which previously disagreed because
  /// `record` reports PEAK dBFS pre-processing and getStats RMS post.
  ///
  /// [localReported] distinguishes "this PC says we are silent" from "this
  /// PC carried no outgoing audio report at all": only the former ends the
  /// search, so a receive-only PC falls through instead of pinning us silent.
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
      final fwdIn = _fwdIn[peerId] ?? const {};
      final fwdOut = _fwdOut[peerId] ?? const {};
      final fwdSources = {
        for (final r in stats)
          if (r.type == 'media-source' &&
              fwdOut.containsKey(r.values['trackIdentifier']))
            r.id,
      };
      for (final report in stats) {
        if (report.values['kind'] != 'audio') continue;
        if (fwdIn.containsKey(report.values['trackIdentifier']) ||
            fwdSources.contains(report.id) ||
            fwdSources.contains(report.values['mediaSourceId'])) {
          continue;
        }
        switch (report.type) {
          case 'inbound-rtp':
            remote = _detectSpeech(report.values, 'in-$peerId');
            _remoteLevels[peerId] =
                levelFromAudioLevel(report.values['audioLevel'] as num?);
            // Local: media-source carries audioLevel on Android,
            // outbound-rtp on desktop. Take either, keeping SEPARATE energy
            // keys so one's totalAudioEnergy fallback cannot consume the
            // other's delta within a single poll.
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

  /// Detects speech from an RTP stats report, by totalAudioEnergy delta or
  /// direct audioLevel.
  bool _detectSpeech(Map<dynamic, dynamic> values, String key) {
    final level = (values['audioLevel'] as num?)?.toDouble();
    if (level != null) return level > 0.01;

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

  Future<RTCPeerConnection> _createPeerConnection(String peerId) async {
    await closePeer(peerId);

    final pc = await createPeerConnection(iceServers);
    _peerConnections[peerId] = pc;
    _remoteDescSet[peerId] = false;
    _pendingCandidates[peerId] = [];

    pc.onIceCandidate = (candidate) => _onLocalIceCandidate(peerId, candidate);
    pc.onConnectionState = (state) =>
        _onPeerConnectionState(peerId, pc, state);
    // Remote audio plays automatically via the libwebrtc default sink; in
    // gossip mode received tracks are also forwarded to other neighbors.
    pc.onTrack = (RTCTrackEvent event) => _onPeerTrack(peerId, pc, event);

    return pc;
  }

  /// onIceCandidate handler: relays each locally gathered candidate to the
  /// peer over the MLS-encrypted signal channel.
  void _onLocalIceCandidate(String peerId, RTCIceCandidate candidate) {
    if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
    if (_serverId == null || _channelId == null) return;

    final payload = jsonEncode({
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
      // .catchError, not try/catch: a sync try/catch around the un-awaited
      // Future catches nothing. Safe to swallow, since candidates are
      // best-effort and the connection renegotiates without this one.
    network_api.voiceChannelSendSignal(
      serverId: _serverId!,
      channelId: _channelId!,
      peerId: peerId,
      signalType: 'ice',
      payload: payload,
    ).catchError((_) {});
  }

  /// onConnectionState handler: fires onPeerConnected plus a delayed
  /// ICE-route log on connect, and tears the PC down on failed or closed.
  void _onPeerConnectionState(
      String peerId, RTCPeerConnection pc, RTCPeerConnectionState state) {
    _vcLog('[HOLLOW-VC] Connection state with $peerId: $state');
    unawaited(_reconcileAloneMeter());
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      onPeerConnected?.call(peerId);
      _logIceRoute(peerId, pc);
      scheduleIceRepair(peerId);
      // Clear the flair explicitly: a leg we had given up on is republished
      // as `lost`, and the FRESH watchdog that replaces it starts out
      // believing it already published "healthy", so it would never say so.
      onLinkHealth?.call(peerId, const LinkHealthSnapshot());
      _startLinkWatch(peerId);
      // The leg is back: stop reaching for it, and put back the receive-side
      // state the fresh receiver does not carry (deafen, per-peer volume).
      _legRedial.remove(peerId)?.cancel();
      unawaited(_restorePeerAudioState(peerId));
      unawaited(_forwardGossipSources());
      // Asked again: a want that beat the far side's leg was dropped there.
      _wantSent.remove(peerId);
      _scheduleWants();
    }
    // Our own teardown reports `closed` right back here; that is not the
    // remote end going away.
    if (_closingPeers.contains(peerId)) return;

    final watch = _linkWatch[peerId];
    if (watch != null) {
      // The leg has been up before, so trouble now earns the hold-open
      // ladder: hold it, restart ICE, close only once the window is spent.
      watch.noteTransportState(state);
      return;
    }
    // Never connected: a setup failure for this leg, which the mesh's own
    // join machinery retries.
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
        onLegGiveUp?.call(peerId);
        unawaited(closePeer(peerId).then((_) {
          // `closePeer` stops the watchdog, and a stopped watchdog publishes
          // a HEALTHY snapshot, which would wipe the flair off a member we
          // can no longer hear. Keep saying what is true until the leg is
          // actually back.
          onLinkHealth?.call(
              peerId, const LinkHealthSnapshot(health: LinkHealth.lost));
        }));
        // Not the end of the story the way a DM hangup is: this member is
        // still sitting in the channel, so keep trying to reach them.
        _scheduleLegRedial(peerId);
      },
    )..start();
  }

  /// Rebuilds the media leg to [peerId] without leaving the channel.
  ///
  /// Drop the leg and bring it up from scratch, exactly as a member joining
  /// does: `_createPeerConnection` closes any existing PC first, so the fresh
  /// offer rebuilds BOTH ends and both get new SFrame cryptors in the
  /// known-good order rather than repaired in place.
  ///
  /// The mesh gives the offer to the lexicographically LOWER id, which left
  /// the higher side with no recovery at all: it closed its leg and waited
  /// for an offer nobody was going to send. It asks now, with
  /// [_sendLegRestart].
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

  /// Tears the leg down and offers a fresh one. Only ever called on the
  /// DIALING side: two crossing rebuilds would ping-pong closing each other's
  /// fresh peer connection, since `_createPeerConnection` closes what it finds.
  Future<void> _redialLeg(String peerId) async {
    _vcLog('[HOLLOW-VC] $peerId: rebuilding the leg (we dial)');
    await closePeer(peerId);
    // `closePeer` stops the watchdog, and a stopped watchdog publishes
    // HEALTHY, so without this the flair blinks off for the whole rebuild,
    // exactly when the member is least able to hear us.
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
      // Only the dialing side may act on this. Honouring it here would mint
      // a second dialer and put us straight back into the glare this avoids.
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

  /// Keeps reaching for a leg whose hold-open window was spent.
  ///
  /// Slow on purpose: a leg only reaches here after the ladder held it for
  /// the full window, so the network is properly down rather than wobbling.
  /// Stops on its own once the leg comes back or the member leaves.
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
        // Our own relay link is down, so the offer would be dropped before
        // it left the machine. Wait rather than spend an attempt on nothing.
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

  /// Puts back what a fresh receiver does not carry over.
  ///
  /// Mute rides the shared local track and survives a rebuild untouched, but
  /// deafen and any per-peer volume are set ON the receiver, which the
  /// rebuild replaced: without this, un-deafening was the only way to get a
  /// rebuilt leg back to the volume the user had chosen.
  Future<void> _restorePeerAudioState(String peerId) async {
    double wanted() => _wantedVolume(peerId);
    if (wanted() == 1.0) return;
    _vcLog('[HOLLOW-VC] Restoring playback volume ${wanted()} for $peerId');
    await _applyRemoteVolume(peerId, wanted());
    // Re-assert a moment later: Android knows a receiver only once its track
    // event fired, and `setVolume` before that is a TOLERATED no-op, so the
    // first attempt can vanish without a sound. Silently leaving a deafened
    // member audible is the failure worth the second call.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!_peerConnections.containsKey(peerId)) return;
    if (wanted() == 1.0) return;
    await _applyRemoteVolume(peerId, wanted());
  }

  /// Holds the camera we send to ONE peer to [rung].
  ///
  /// Per peer, because in a mesh each leg has its own sender and its own
  /// uplink problem: one member on a bad connection gets a smaller picture
  /// of us and nobody else pays for it.
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

  /// Logs which ICE route the succeeded candidate pair took. Diagnostics
  /// only.
  Future<void> _logIceRoute(String peerId, RTCPeerConnection pc) async {
    final route = await probeIceRoute(() => pc);
    _vcLog(route == null
        ? '[HOLLOW-VC] ICE route to $peerId: no succeeded candidate pair found'
        : '[HOLLOW-VC] ICE route to $peerId: $route');
  }

  /// Peers whose one-shot ICE repair has already been spent this session.
  final Set<String> _iceRepairDone = {};

  /// Peers with a renegotiation we started in flight. Glare is normally
  /// arbitrated inline by signalingState plus the peer-id tiebreak, but an
  /// ICE restart is a NEW renegotiation source, so it gets an explicit busy
  /// flag rather than leaning on that tiebreak.
  final Set<String> _renegInFlight = {};

  /// Whether "Always relay calls" is on, injected so the service never
  /// reaches into Riverpod. Forced-relay users must NEVER be repaired to
  /// direct: that routing is a deliberate privacy choice.
  bool Function()? isForcedRelay;

  /// One-shot "direct whenever direct is possible" repair for a mesh PC; see
  /// `ice_repair.dart` for why the nomination race makes it necessary and why
  /// exactly one attempt is the right budget.
  ///
  /// The highest-value lane for it: a VC audio PC repaired to direct is also
  /// what flips the screen-share `route` hint to `direct`, which lets the
  /// sharer promote this viewer onto a peer branch.
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
  /// the provider can refresh anything keyed on the route, notably the
  /// screen-watch hint.
  void Function(String peerId, bool direct)? onIceRouteRepaired;

  /// onTrack handler: bind SFrame receivers for the new audio/video track,
  /// then (gossip mode only) forward received audio to other neighbors.
  void _onPeerTrack(String peerId, RTCPeerConnection pc, RTCTrackEvent event) {
    final fwdOrigin = event.track.kind == 'audio' && event.streams.isNotEmpty
        ? forwardOriginOfStream(event.streams.first.id)
        : null;
    if (fwdOrigin != null && _acceptsForward(peerId, fwdOrigin)) {
      unawaited(_receiveForwarded(peerId, fwdOrigin, event));
      return;
    }
    if (event.track.kind == 'audio') {
      // REBIND, not just enable: a remote mid-call mic switch lands as a NEW
      // transceiver, and _enableSframeReceiver is idempotent per
      // (peer, kind), so it would silently keep the cryptor on the dead
      // receiver and the fresh track would play as ciphertext.
      unawaited(_rebindSframeReceiver(peerId, pc, event.receiver));
      // A receiver starts at full volume: one the peer opens while we are
      // deafened or have turned it down must not play through.
      final receiver = event.receiver;
      final volume = _wantedVolume(peerId);
      if (receiver != null && volume != 1.0) {
        unawaited(setRemoteReceiverVolume(volume, receiver));
      }
    } else if (event.track.kind == 'video') {
      _handleRemoteVideoTrack(peerId, event, pc);
    }

    _forwardGossipAudio(peerId, event);
  }

  /// Gossip: a voice heard straight from its speaker, kept so it can go on to
  /// a leg that asks for it, one hop only.
  void _forwardGossipAudio(String peerId, RTCTrackEvent event) {
    if (event.track.kind != 'audio' || event.streams.isEmpty) return;
    _gossipSources[peerId] = (event.track, event.streams.first);
    unawaited(_forwardGossipSources());
  }

  /// Puts on each leg exactly the voices it asked for and we hear straight,
  /// each sender under its own SFrame cryptor BEFORE the renegotiation that
  /// carries it: with no key yet nothing is forwarded, and [setSframeKey]
  /// runs this again.
  Future<void> _forwardGossipSources() =>
      _fwdSync = _fwdSync.then((_) => _syncForwards()).catchError((_) {});

  Future<void> _syncForwards() async {
    final fc = frameCryptor;
    // A want proves the asker is in gossip, whatever this side was last told.
    final keyed = gossipForwardingEnabled && fc != null && fc.isEnabled;
    for (final leg in _peerConnections.keys.toList()) {
      final pc = _peerConnections[leg];
      if (pc == null) continue;
      final want = keyed
          ? forwardsFor(
              leg: leg,
              self: localPeerId,
              wanted: _fwdWanted[leg] ?? const {},
              heard: _gossipSources.keys.toSet())
          : const <String>{};
      final out = _fwdOut[leg] ??= {};
      final asked = _fwdWanted[leg] ?? const <String>{};
      if (asked.isNotEmpty &&
          !_setEquals(want, {for (final v in out.values) v.origin})) {
        _vcLog('[HOLLOW-VC] Gossip: want from $leg: asked=$asked '
            'heard=${_gossipSources.keys.toSet()} forwards=$want keyed=$keyed');
      }
      var changed = false;
      for (final e in out.entries.toList()) {
        final origin = e.value.origin;
        if (want.contains(origin) && _gossipSources[origin]?.$1.id == e.key) {
          continue;
        }
        out.remove(e.key);
        changed = true;
        try {
          await pc.removeTrack(e.value.sender);
        } catch (_) {}
        if (!out.values.any((v) => v.origin == origin)) {
          await fc?.disableKind(leg, forwardCryptorKind(origin));
        }
      }
      for (final origin in want) {
        final (track, stream) = _gossipSources[origin]!;
        final trackId = track.id;
        if (trackId == null || out.containsKey(trackId)) continue;
        RTCRtpSender? sender;
        try {
          sender = await pc.addTrack(track, stream);
          final kind = forwardCryptorKind(origin);
          await fc!.rebindSender(leg, sender, kind: kind);
          if (!fc.encrypts(leg, sender, kind: kind)) {
            throw StateError('no SFrame cryptor bound');
          }
          out[trackId] = (origin: origin, sender: sender);
          changed = true;
          _vcLog('[HOLLOW-VC] Gossip: forwarding $origin to $leg under SFrame');
        } catch (e) {
          if (sender != null) {
            try {
              await pc.removeTrack(sender);
            } catch (_) {}
          }
          _vcLog('[HOLLOW-VC] Gossip: forward of $origin to $leg failed: $e');
        }
      }
      if (changed) _fwdReneg.touch(leg);
    }
  }

  /// Binds a decryptor to each voice [peerId] forwards to us, for a key that
  /// landed after the track did; [fresh] re-creates a binding that may be wedged.
  Future<void> _bindForwardedReceivers(String peerId, RTCPeerConnection pc,
      {bool fresh = false}) async {
    final fc = frameCryptor;
    final forwarded = _fwdIn[peerId];
    if (fc == null || !fc.isEnabled || forwarded == null || forwarded.isEmpty) {
      return;
    }
    try {
      for (final r in await pc.getReceivers()) {
        final origin = forwarded[r.track?.id];
        if (origin == null) continue;
        final kind = forwardCryptorKind(origin);
        if (fresh) await fc.disableReceiver(peerId, kind: kind);
        await fc.rebindReceiver(peerId, r, kind: kind);
      }
    } catch (e) {
      _vcLog('[HOLLOW-VC] Gossip: forwarded decryptor bind failed for $peerId: $e');
    }
  }

  /// One renegotiation carries a burst of forward changes to [peerId].
  Future<void> _renegotiateForwards(String peerId) async {
    final pc = _peerConnections[peerId];
    if (pc == null) return;
    if (pc.signalingState != RTCSignalingState.RTCSignalingStateStable) {
      _fwdReneg.touch(peerId);
      return;
    }
    _vcLog('[HOLLOW-VC] Gossip: renegotiating $peerId for its forwards');
    // A forward changes no camera, so the far side's camera net must not run.
    await _sendRenegotiationOffer(peerId, iceRestart: true);
  }

  /// [peerId] asked us for the voices it hears from no leg of its own.
  void _onForwardWant(String peerId, String payload) {
    if (!_peerConnections.containsKey(peerId)) return;
    final origins = <String>{};
    try {
      final list = (jsonDecode(payload) as Map)['origins'];
      if (list is List) origins.addAll(list.whereType<String>());
    } catch (_) {
      return;
    }
    _fwdWanted[peerId] = origins;
    _vcLog('[HOLLOW-VC] Gossip: $peerId asks for ${origins.length} forwarded voices');
    unawaited(_forwardGossipSources());
  }

  void _scheduleWants() {
    _wantsTimer?.cancel();
    _wantsTimer = Timer(const Duration(milliseconds: 400), _sendWants);
  }

  /// Tells each leg whom we hear from no leg at all, when that changed.
  void _sendWants() {
    final sid = _serverId, cid = _channelId;
    if (sid == null || cid == null) return;
    final members = channelMembers?.call() ?? const <String>{};
    final settling = _awaitNeighbourLegs(members);
    if (!gossipForwardingEnabled) return;
    final want = forwardWants(
      gossip: gossipMode,
      self: localPeerId,
      members: members,
      live: _linkWatch.keys.toSet(),
      settling: settling,
    );
    for (final leg in _peerConnections.keys) {
      if (_setEquals(_wantSent[leg] ?? const {}, want)) continue;
      _wantSent[leg] = want;
      network_api
          .voiceChannelSendSignal(
            serverId: sid,
            channelId: cid,
            peerId: leg,
            signalType: 'fwd_want',
            payload: jsonEncode({'origins': want.toList()..sort()}),
          )
          .catchError((_) {});
    }
  }

  /// The neighbours whose leg is still inside its setup grace. A leg past it
  /// never formed (an offer can land before the far side's voice channel
  /// exists, and nothing else retries a leg that never connected), so we reach
  /// for it again, more slowly each time, until it comes up.
  Set<String> _awaitNeighbourLegs(Set<String> members) {
    final expected = gossipMode
        ? {
            for (final n in gossipNeighbors)
              if (n != localPeerId && members.contains(n)) n,
          }
        : const <String>{};
    _legAwaited.removeWhere(
        (p, _) => !expected.contains(p) || _linkWatch.containsKey(p));
    final now = DateTime.now();
    final settling = <String>{};
    DateTime? next;
    for (final p in expected) {
      if (_linkWatch.containsKey(p)) continue;
      var w = _legAwaited[p] ??=
          (since: now, reachAt: now.add(legSetupGrace), reaches: 0);
      if (!now.isBefore(w.reachAt)) {
        final reaches = w.reaches + 1;
        final backoff = Duration(
            milliseconds:
                (legSetupGrace.inMilliseconds * reaches).clamp(0, 60000));
        w = _legAwaited[p] =
            (since: w.since, reachAt: now.add(backoff), reaches: reaches);
        _vcLog('[HOLLOW-VC] Gossip: no leg to neighbour $p after '
            '${now.difference(w.since).inSeconds} s, reaching for it '
            '(attempt $reaches)');
        unawaited(_rebuildLeg(p));
      }
      if (w.reaches == 0) settling.add(p);
      if (next == null || w.reachAt.isBefore(next)) next = w.reachAt;
    }
    _legGraceTimer?.cancel();
    _legGraceTimer = next == null
        ? null
        : Timer(next.difference(now) + const Duration(milliseconds: 20),
            _sendWants);
    return settling;
  }

  /// A voice [forwarder] forwards for [origin]: decrypted under its own
  /// cryptor, never taken for the forwarder's microphone, never forwarded
  /// again, and silent while [origin] is heard another way.
  Future<void> _receiveForwarded(
      String forwarder, String origin, RTCTrackEvent event) async {
    final trackId = event.track.id;
    if (trackId != null) (_fwdIn[forwarder] ??= {})[trackId] = origin;
    final fc = frameCryptor;
    final receiver = event.receiver;
    if (fc != null && receiver != null) {
      await fc.rebindReceiver(forwarder, receiver,
          kind: forwardCryptorKind(origin));
    }
    final heardElsewhere = origin == localPeerId ||
        _peerConnections.containsKey(origin) ||
        _fwdIn.entries.any((e) =>
            e.key != forwarder &&
            e.value.entries.any((t) =>
                t.value == origin &&
                !(_fwdSilent[e.key]?.contains(t.key) ?? false)));
    if (trackId != null && (heardElsewhere || _isDeafened)) {
      if (heardElsewhere) (_fwdSilent[forwarder] ??= {}).add(trackId);
      // Again a moment later: a receiver the platform has not reported yet
      // takes the volume call as a tolerated no-op.
      for (final wait in const [Duration.zero, Duration(milliseconds: 800), Duration(seconds: 3)]) {
        await Future<void>.delayed(wait);
        if (!_peerConnections.containsKey(forwarder)) return;
        if (!(_fwdSilent[forwarder]?.contains(trackId) ?? false) &&
            !_isDeafened) {
          break;
        }
        if (receiver != null) await setRemoteReceiverVolume(0.0, receiver);
      }
    }
    _vcLog('[HOLLOW-VC] Gossip: $forwarder forwards $origin'
        '${heardElsewhere ? ' (heard directly, kept silent)' : ''}');
    if (trackId != null) unawaited(_logForwardedBytes(forwarder, origin, trackId));
  }

  /// Once per forwarded track: its received bytes 2 s and 6 s after it
  /// landed, so a run can tell a forward that flows from one that does not.
  Future<void> _logForwardedBytes(
      String forwarder, String origin, String trackId) async {
    var at = 0;
    for (final second in const [2, 6]) {
      await Future<void>.delayed(Duration(seconds: second - at));
      at = second;
      final pc = _peerConnections[forwarder];
      if (pc == null) return;
      try {
        for (final r in await pc.getStats()) {
          if (r.type == 'inbound-rtp' &&
              r.values['trackIdentifier'] == trackId) {
            _vcLog('[HOLLOW-VC] Gossip: forwarded $origin via $forwarder '
                'bytesReceived=${r.values['bytesReceived']} at ${second}s');
          }
        }
      } catch (_) {}
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

  /// Inserts [fmtpLine] right after the opus rtpmap line and rejoins the
  /// SDP, for an SDP with no existing a=fmtp line for opus.
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

  /// Constrains the transceiver carrying [trackId] on [pc] to VP8 only, plus
  /// rtx/red/ulpfec. VP8 is software everywhere and is what negotiation picks
  /// anyway; H.265/AV1 payload types kill the iOS answerer, and even H264/VP9
  /// entries make iOS's FIRST call fail applying its own answer while its
  /// hardware codec path is cold. Also covers Apple's H.264 profile not
  /// decoding on Windows libwebrtc.
  Future<void> _preferVp8ForVideoTrackOnPc(
      RTCPeerConnection pc, String trackId) async {
    try {
      final (safe, all) = await _vp8VideoCodecs();
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

  /// VP8 plus rtx/red/ulpfec, and every video codec we could send.
  Future<(List<RTCRtpCodecCapability>, List<RTCRtpCodecCapability>)>
      _vp8VideoCodecs() async {
    final caps = await getRtpSenderCapabilities('video');
    final all = caps.codecs ?? const <RTCRtpCodecCapability>[];
    bool mimeIs(RTCRtpCodecCapability c, String name) =>
        c.mimeType.toLowerCase() == 'video/$name';
    return (
      [
        ...all.where((c) => mimeIs(c, 'vp8')),
        ...all.where(
            (c) => mimeIs(c, 'rtx') || mimeIs(c, 'red') || mimeIs(c, 'ulpfec')),
      ],
      all,
    );
  }

  /// Every video section of a re-offer, VP8 only. Each leg's first offer asks
  /// to receive video, so a leg we answered keeps the offerer's codec list,
  /// and an iOS re-offer carrying its H.264/H.265/AV1 entries fails to apply.
  Future<void> _offerVideoAsVp8Only(RTCPeerConnection pc) async {
    final List<RTCRtpCodecCapability> safe;
    final List<RTCRtpTransceiver> transceivers;
    try {
      (safe, _) = await _vp8VideoCodecs();
      if (safe.isEmpty) return;
      transceivers = await pc.getTransceivers();
    } catch (e) {
      _vcLog('[HOLLOW-VC] Video codec narrowing before a re-offer failed: $e');
      return;
    }
    // One transceiver at a time: a stopped one throws, and the rest must
    // still leave VP8-only.
    for (final t in transceivers) {
      try {
        if (t.receiver.track?.kind == 'video' ||
            t.sender.track?.kind == 'video') {
          await t.setCodecPreferences(safe);
        }
      } catch (e) {
        _vcLog('[HOLLOW-VC] Video codec narrowing skipped a transceiver: $e');
      }
    }
  }
}

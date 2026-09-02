import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:hollow/src/core/hollow_data_dir.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;
import 'ice_route_probe.dart';
import 'wire_transfer_id.dart';

/// Chunk size for WebRTC data channel transfers.
/// 64KB per message is safe across all platforms (SCTP max is ~256KB).
/// With flutter_webrtc 1.4.1 (libwebrtc m144) and proper getBufferedAmount()
/// backpressure, we can send these at full speed without buffer overflow.
const _kChunkSize = 64 * 1024;

/// Max bytes to buffer in the SCTP send queue before waiting.
/// Keep well below the 16MB data channel buffer limit.
/// 256KB is conservative — lets ~4 chunks be in-flight at once.
const _kMaxBufferedAmount = 256 * 1024;
const _kTypeFile = 0x00;
const _kTypeShard = 0x01;
const _kTypeShareChunk = 0x02;
const _kTypeContinuation = 0xFF;
const _kTypeScreenAudio = 0x03; // screen share audio (Opus packets)
const _kTypeGossipOp = 0x04; // small gossip frame (CRDT op JSON, Tier 2 scaling)
const _kTypePing = 0xFE; // keepalive ping byte
const _kTypePong = 0xFC; // keepalive pong response byte

/// Which transport a peer connection belongs to.
///
/// [general] is the multiplexed `hollow-data` channel: DM/channel file
/// transfers, vault shards, screen-share audio, gossip frames. It is built from
/// the general ICE config, which carries TURN (and is TURN-ONLY while "Always
/// relay calls" is on).
///
/// [share] is a SECOND, dedicated peer connection used only by Hollow Share
/// (including the hidden >34 MB chat-file variant). It is always built from the
/// STUN-only Share config, so Share bytes can never ride the relay
/// (HOLLOW_PLAN §7A). Before this split, Share reused the general connection
/// whenever one already existed — i.e. for anyone you actually chat with — and
/// silently inherited its TURN candidates.
enum _Lane { general, share }

/// Signal types on the wire. The Share lane has its OWN types (and its own
/// `HavenMessage` variants in Rust) instead of a flag on the general ones, so a
/// client that predates the Share lane fails to parse them and drops them at
/// the envelope layer. Reusing `offer` would make that client treat a Share
/// offer as a general one and tear down its live `hollow-data` connection over
/// the glare tiebreaker (or ignore it and flap) — collateral damage to DMs,
/// files and screen audio for a feature it doesn't have.
const _kSigOffer = 'offer';
const _kSigAnswer = 'answer';
const _kSigIce = 'ice';
const _kSigShareOffer = 'share_offer';
const _kSigShareAnswer = 'share_answer';
const _kSigShareIce = 'share_ice';

/// Idle timeout before closing a peer connection (3x keepalive interval).
const _kIdleTimeout = Duration(seconds: 90);

/// Keepalive ping interval — keeps the data channel alive.
const _kKeepaliveInterval = Duration(seconds: 30);

/// Default ICE servers (STUN only — used if no config injected).
Map<String, dynamic> _defaultIceServers({String domain = 'relay.anonlisten.com'}) => {
  'iceServers': [
    {'urls': 'stun:$domain:3478'},
    {'urls': 'stun:stun.cloudflare.com:3478'},
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
};

/// Log to hollow_debug.log (visible in release builds).
void _log(String msg) {
  network_api.logFromDart(message: msg);
}

/// Manages WebRTC peer connections and data channel file streaming.
class WebRtcService {
  final String localPeerId;

  /// Resolve a (possibly per-device) peer_id to its MASTER identity
  /// (multi-device, Phase 6). Used ONLY for the glare tiebreaker, which must
  /// compare two ids of the same kind on BOTH peers or it isn't antisymmetric:
  /// the relay reports DEVICE ids, but a multi-device peer may surface as
  /// different device ids on each side (e.g. it offers as its master id while
  /// the remote sees the device id), so comparing raw ids lets BOTH sides pick
  /// "impolite" → neither answers → the data channel never opens (the same
  /// device-vs-master deadlock as the Olm KeyBundle glare). Resolving both ids
  /// to master makes the comparison identical on both machines. Defaults to a
  /// no-op (single-device / unknown peer resolves to itself). Sockets, sends,
  /// and connection keys stay on the DEVICE id — never resolve those.
  final String Function(String peerId) resolveIdentity;

  /// ICE configuration (STUN + TURN). Updated by IceConfigProvider.
  /// GENERAL lane only — the Share lane never reads this.
  Map<String, dynamic> iceServers;

  /// Relay domain, for the STUN-only fallback config used when a Share offer
  /// arrives before we've been told this peer's Share config.
  final String relayDomain;

  /// Active GENERAL peer connections: peer_id -> _PeerConn
  final Map<String, _PeerConn> _connections = {};

  /// Active SHARE peer connections: peer_id -> _PeerConn. Deliberately a second
  /// connection to the same peer — see [_Lane].
  final Map<String, _PeerConn> _shareConnections = {};

  /// Active incoming transfers: transfer_id -> _IncomingTransfer
  final Map<String, _IncomingTransfer> _transfers = {};

  /// Queued ICE candidates that arrived before the connection was created.
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};

  /// Callback to request reconnection after a non-idle disconnect.
  void Function(String peerId)? onReconnectNeeded;

  /// Peers we're intentionally closing (idle timeout or manual).
  /// Prevents triggering reconnect for intentional disconnects.
  final Set<String> _intentionalClose = {};
  final Set<String> _shareIntentionalClose = {};

  /// Guards against concurrent connectToPeer calls for the same peer.
  final Set<String> _connecting = {};
  final Set<String> _shareConnecting = {};

  /// Timestamp of last keepalive ping sent per peer (for RTT measurement).
  final Map<String, DateTime> _pingSentAt = {};

  /// Progress callback (transferId, bytesDone, totalBytes).
  void Function(String transferId, int bytesDone, int totalBytes)? onProgress;

  /// Called when a send completes successfully.
  void Function(String transferId)? onSendComplete;

  /// Called when a receive completes (transferId, tempPath, senderPeerId, kind, shardIndex).
  void Function(String transferId, String tempPath, String senderPeerId,
      String kind, int shardIndex)? onReceiveComplete;

  /// Called when a screen audio packet is received from a peer.
  /// Payload is raw bytes: [seq:4][opus_data...].
  void Function(String peerId, Uint8List data)? onScreenAudioReceived;
  int _screenAudioMissCount = 0;

  // Screen-audio send backpressure. The 'hollow-data' channel is reliable +
  // ordered (file transfers need that), but screen audio streams ~250 small
  // packets/sec. If the channel can't drain fast enough (e.g. a TURN-relayed
  // route), the SCTP send buffer climbs and libwebrtc CLOSES the channel the
  // moment it hits its 16MB cap (proven: Mac->Win share died ~9s in over TURN).
  // So we DROP screen-audio packets while the buffer is backed up beyond this
  // threshold — for real-time audio a dropped stale packet is a tiny glitch,
  // whereas a multi-MB backlog is seconds of latency followed by channel death.
  static const int _kScreenAudioMaxBufferedBytes = 256 * 1024; // 256 KB
  int _screenAudioSent = 0;
  int _screenAudioDropped = 0;
  // Desktop (Win/macOS) native flutter_webrtc does NOT push bufferedAmount-change
  // events, so the cached `dc.bufferedAmount` getter stays 0 forever — we must
  // poll the real value via the async getBufferedAmount(). Polling per packet
  // (~250/sec) would flood the method channel, so we cache the last reading per
  // peer and refresh it at most once per _kBufferPollEveryNSends sends.
  final Map<String, int> _screenAudioBufferedCache = {};
  final Set<String> _screenAudioBufferPolling = {};
  int _screenAudioSendTick = 0;
  static const int _kBufferPollEveryNSends = 12;

  /// Called when a STUN-only (Share) connection fails — peer unreachable without TURN.
  void Function(String peerId)? onShareConnectionFailed;

  /// STUN-only ICE config remembered per Share peer, so an offer we ANSWER is
  /// built from the Share config too.
  ///
  /// Entries deliberately OUTLIVE the connection: a dropped link is re-offered
  /// by the remote within a tick, and forgetting on cleanup would leave the
  /// answer path guessing. Keeping it costs no privacy — a peer we ever
  /// exchanged Share candidates with has already seen this address.
  final Map<String, Map<String, dynamic>> _shareIceConfig = {};

  WebRtcService({
    required this.localPeerId,
    Map<String, dynamic>? iceServers,
    this.relayDomain = 'relay.anonlisten.com',
    String Function(String peerId)? resolveIdentity,
  })  : iceServers = iceServers ?? _defaultIceServers(domain: relayDomain),
        resolveIdentity = resolveIdentity ?? ((p) => p);

  // ── Lane plumbing ──

  Map<String, _PeerConn> _connsFor(_Lane lane) =>
      lane == _Lane.share ? _shareConnections : _connections;

  Set<String> _connectingFor(_Lane lane) =>
      lane == _Lane.share ? _shareConnecting : _connecting;

  Set<String> _intentionalFor(_Lane lane) =>
      lane == _Lane.share ? _shareIntentionalClose : _intentionalClose;

  String _sigOffer(_Lane lane) =>
      lane == _Lane.share ? _kSigShareOffer : _kSigOffer;
  String _sigAnswer(_Lane lane) =>
      lane == _Lane.share ? _kSigShareAnswer : _kSigAnswer;
  String _sigIce(_Lane lane) => lane == _Lane.share ? _kSigShareIce : _kSigIce;

  String _tag(_Lane lane) => lane == _Lane.share ? 'share' : 'general';

  /// ICE config for a Share connection to [peerId]. Never the general config:
  /// falls back to the plain STUN-only default when the Share tick hasn't
  /// handed us one yet (an offer can land before our own tick fires).
  Map<String, dynamic> _shareConfigFor(String peerId) =>
      _shareIceConfig[peerId] ?? _defaultIceServers(domain: relayDomain);

  /// Find the live, OPEN connection to the person identified by [peerId],
  /// resolving device<->master. `_connections` is DEVICE-keyed (the routable
  /// socket), but callers from the call/screen-share layer pass the MASTER id.
  /// A direct `_connections[master]` therefore misses the call's real channel
  /// (keyed under a device id) — so fall back to matching any open connection
  /// whose identity resolves to the same master. This is the device->master
  /// collapse the rest of the codebase already does; the screen-audio path
  /// needs it too (otherwise sends to the master are silently dropped and a
  /// doomed 2nd connect-to-bare-master times out). See
  /// feedback_webrtc_datachannel_multidevice.
  _PeerConn? _openConnForIdentity(String peerId, [_Lane lane = _Lane.general]) {
    final map = _connsFor(lane);
    final direct = map[peerId];
    if (direct?.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      return direct;
    }
    final wantId = resolveIdentity(peerId);
    for (final conn in map.values) {
      if (conn.dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
        continue;
      }
      if (resolveIdentity(conn.peerId) == wantId) return conn;
    }
    return null;
  }

  /// Check if a peer has an active GENERAL data channel (device<->master aware).
  bool hasPeerChannel(String peerId) {
    return _openConnForIdentity(peerId) != null;
  }

  /// Check if a peer has an active SHARE data channel.
  bool hasShareChannel(String peerId) {
    return _openConnForIdentity(peerId, _Lane.share) != null;
  }

  /// Send a screen audio packet to a peer over the existing data channel.
  /// Format: [0x03][payload...]. Payload is [seq:4][opus_data...].
  void sendScreenAudio(String peerId, Uint8List payload) {
    // Resolve to the call's actual (device-keyed) open channel — the caller
    // passes the MASTER id, which isn't a key in _connections. Without this the
    // lookup misses and every audio packet is silently dropped.
    var conn = _openConnForIdentity(peerId);
    // Last-resort fallback: if identity resolution didn't match (e.g. the local
    // device-link map is cold and doesn't yet know this peer's device<->master
    // association) BUT there's exactly ONE open data channel, it's the call peer
    // — use it. Scoped to screen audio only; file transfers never take this path.
    // Only when the channel's owner is UNKNOWN to the link map — a resolvable
    // owner that didn't match above is a DIFFERENT person (multi-viewer VC
    // share), and routing this viewer's audio into their channel would double it.
    if (conn == null) {
      final open = _connections.values
          .where((c) =>
              c.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen)
          .toList();
      if (open.length == 1 &&
          resolveIdentity(open.first.peerId) == open.first.peerId) {
        conn = open.first;
        if (_screenAudioSent == 0 && _screenAudioDropped == 0) {
          _log('[HOLLOW-WEBRTC-DART] screen-audio: id $peerId unresolved, '
              'using the single open channel ${conn.peerId}');
        }
      }
    }
    final dc = conn?.dataChannel;
    if (conn == null || dc == null ||
        dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    final connKey = conn.peerId; // device id — the real connection/cache key

    // Backpressure: if the SCTP send buffer is backed up, DROP this packet
    // rather than queue it. Queuing real-time audio just adds latency and, once
    // the buffer hits libwebrtc's 16MB cap, the channel is force-closed. Dropping
    // a stale packet is the correct real-time behavior.
    _maybeRefreshScreenAudioBuffer(connKey, dc);
    final buffered = _screenAudioBufferedCache[connKey] ?? 0;
    if (buffered > _kScreenAudioMaxBufferedBytes) {
      _screenAudioDropped++;
      if (_screenAudioDropped <= 5 || _screenAudioDropped % 250 == 0) {
        _log('[HOLLOW-WEBRTC-DART] screen-audio backpressure: dropped '
            '$_screenAudioDropped (buffered=${buffered}B sent=$_screenAudioSent)');
      }
      return;
    }

    final packet = Uint8List(1 + payload.length);
    packet[0] = _kTypeScreenAudio;
    packet.setRange(1, packet.length, payload);
    try {
      dc.send(RTCDataChannelMessage.fromBinary(packet));
      _screenAudioSent++;
    } catch (e) {
      // A failed send (e.g. transient buffer-full) must NOT kill the stream.
      _screenAudioDropped++;
      if (_screenAudioDropped <= 5) {
        _log('[HOLLOW-WEBRTC-DART] screen-audio send failed (dropped): $e');
      }
    }
  }

  /// Refresh the cached SCTP buffered-bytes for [peerId] at most once every
  /// _kBufferPollEveryNSends sends (desktop native has no push event, so we poll
  /// the async getter). Fire-and-forget; the cache is read synchronously by the
  /// next send. One poll in flight per peer at a time.
  void _maybeRefreshScreenAudioBuffer(String peerId, RTCDataChannel dc) {
    _screenAudioSendTick++;
    if (_screenAudioSendTick % _kBufferPollEveryNSends != 0) return;
    if (!_screenAudioBufferPolling.add(peerId)) return; // already polling
    dc.getBufferedAmount().then((amount) {
      _screenAudioBufferedCache[peerId] = amount;
    }).catchError((_) {
      // Getter failed (channel gone) — clear so we don't wedge on a stale value.
      _screenAudioBufferedCache.remove(peerId);
    }).whenComplete(() {
      _screenAudioBufferPolling.remove(peerId);
    });
  }

  /// Remember that [peerId] is a Share peer and which STUN-only config it uses,
  /// so the answer path can reuse it. Safe to call repeatedly.
  void noteShareIceConfig(String peerId, Map<String, dynamic> config) {
    _shareIceConfig[peerId] = config;
  }

  /// Initiate the GENERAL WebRTC connection to a peer (offerer side).
  Future<void> connectToPeer(String peerId) async {
    // Already connected or connecting.
    if (_connections.containsKey(peerId)) return;
    // Already have an OPEN channel to this person under a device id (the caller
    // may pass the MASTER, which isn't a _connections key). Don't open a doomed
    // 2nd connection to the bare master — it has no routable socket and times
    // out. Reuse the existing channel.
    if (_openConnForIdentity(peerId) != null) return;
    // Cold device-link map: identity didn't resolve, but if there's already
    // exactly one open channel it's PROBABLY this call peer — don't dial the
    // master. CAVEAT: "cold map" and "a different second person" look the
    // same to the resolver, and blindly reusing here silently skipped dialing
    // a genuine 2nd peer (a late-joining VC screen-share viewer lost its data
    // channel; gossip lost a neighbor). So only take the shortcut when the
    // open channel's owner is UNKNOWN to the link map too — if the map can
    // name that owner (resolves to a different master than [peerId], since
    // _openConnForIdentity above already failed), it's a different person:
    // fall through and dial.
    final open = _connections.values
        .where(
            (c) => c.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen)
        .toList();
    if (open.length == 1 &&
        resolveIdentity(open.first.peerId) == open.first.peerId) {
      _log('[HOLLOW-WEBRTC-DART] connectToPeer($peerId): unresolved but one '
          'open channel exists (owner unknown to link map) — reusing, not '
          'dialing master');
      return;
    }
    await _dial(peerId, _Lane.general, iceServers);
  }

  /// Initiate the dedicated STUN-only SHARE connection to a peer (offerer side).
  ///
  /// This NEVER reuses the general connection, however healthy it is: that
  /// reuse is exactly the hole this lane closes — a Share to anyone you already
  /// chat with inherited the general connection's TURN candidates and pushed
  /// multi-GB payloads through the relay (HOLLOW_PLAN §7A forbids it).
  Future<void> connectShareToPeer(
      String peerId, Map<String, dynamic> config) async {
    // Record the Share config BEFORE any early return — we may not end up
    // dialling (the remote wins the race and we answer instead), but the answer
    // path still needs this peer's STUN-only config.
    noteShareIceConfig(peerId, config);
    if (_shareConnections.containsKey(peerId)) return;
    if (_openConnForIdentity(peerId, _Lane.share) != null) return;
    await _dial(peerId, _Lane.share, config);
  }

  /// Create the peer connection + data channel and send the offer, on [lane].
  Future<void> _dial(
      String peerId, _Lane lane, Map<String, dynamic> config) async {
    final conns = _connsFor(lane);
    if (!_connectingFor(lane).add(peerId)) return;

    final isShare = lane == _Lane.share;
    final connId = _generateConnId();
    _log('[HOLLOW-WEBRTC-DART] Connecting to $peerId '
        '(lane=${_tag(lane)}, conn=$connId, local=$localPeerId)');

    try {
      final pc = await createPeerConnection(config);
      final conn = _PeerConn(
        pc: pc,
        connId: connId,
        peerId: peerId,
        isOfferer: true,
        lane: lane,
      );
      conns[peerId] = conn;
      _connectingFor(lane).remove(peerId);

      // Create data channel (offerer creates it).
      final dcInit = RTCDataChannelInit()
        ..ordered = true;
      final dc = await pc.createDataChannel(
          isShare ? 'hollow-share' : 'hollow-data', dcInit);
      conn.dataChannel = dc;
      _setupDataChannel(dc, peerId, lane);

      // ICE candidate handler.
      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
        // Belt and braces on the Share lane: we configure no TURN server, so a
        // relay candidate should be impossible — never ship one if it is.
        if (isShare && _isRelayCandidate(candidate.candidate!)) {
          _log('[HOLLOW-WEBRTC-DART] Share: dropping our own relay candidate '
              'for $peerId (should be unreachable — STUN-only config)');
          return;
        }
        final payload = jsonEncode({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
        network_api.webrtcSendSignal(
          peerId: peerId,
          signalType: _sigIce(lane),
          payload: payload,
          connId: conn.connId, // Use current connId (may change on glare)
        );
      };

      // Connection state handler.
      pc.onConnectionState = (state) {
        _handleConnectionState(peerId, state, lane);
      };

      // Create and send offer.
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      // Send raw SDP string (not JSON-wrapped — Rust puts it directly in
      // HavenMessage::RtcOffer.sdp / RtcShareOffer.sdp).
      await network_api.webrtcSendSignal(
        peerId: peerId,
        signalType: _sigOffer(lane),
        payload: _stripRelayCandidates(offer.sdp!, lane),
        connId: connId,
      );

      // If the data channel doesn't open within 10s, tear down the stale
      // connection so incoming offers or fresh attempts aren't blocked.
      Future.delayed(const Duration(seconds: 10), () {
        final current = conns[peerId];
        final opened = isShare ? hasShareChannel(peerId) : hasPeerChannel(peerId);
        if (current != null && current.connId == connId && !opened) {
          _log('[HOLLOW-WEBRTC-DART] Connection timeout for $peerId '
              '(lane=${_tag(lane)}, conn=$connId) — no data channel opened');
          _cleanupConnection(peerId, lane);
          _notifyDisconnected(peerId, lane);
        }
      });
    } catch (e) {
      _connectingFor(lane).remove(peerId);
      _log('[HOLLOW-WEBRTC-DART] connectToPeer failed for $peerId '
          '(lane=${_tag(lane)}): $e');
      // A throw after the PC was created+stored (createDataChannel/createOffer/
      // setLocalDescription all throw) leaves a live PC + thread-set in the map.
      // Dispose it — but only if it's still OUR connId (a glare supersede may
      // already have replaced the entry with a newer connection).
      final partial = conns[peerId];
      if (partial != null && partial.connId == connId) {
        await _cleanupConnection(peerId, lane);
      }
    }
  }

  /// True for an ICE candidate line that routes through a TURN server.
  static bool _isRelayCandidate(String candidate) =>
      candidate.contains(' typ relay');

  /// Strip any `typ relay` candidate lines from an SDP on the Share lane.
  ///
  /// Our own SDP can't contain them (no TURN server is configured), and a
  /// current peer's can't either — but a modified or future client's could, and
  /// libwebrtc would happily use a REMOTE relay candidate even though we
  /// gathered none of our own. Stripping locally makes "Share never touches the
  /// relay" something we enforce rather than something we trust the peer for.
  static String _stripRelayCandidates(String sdp, _Lane lane) {
    if (lane != _Lane.share || !sdp.contains(' typ relay')) return sdp;
    final kept = sdp
        .split('\n')
        .where((line) => !(line.startsWith('a=candidate:') &&
            _isRelayCandidate(line)))
        .toList();
    _log('[HOLLOW-WEBRTC-DART] Share: stripped relay candidates from SDP');
    return kept.join('\n');
  }

  /// Handle an incoming signaling message from Rust.
  Future<void> handleSignal(
    String peerId,
    String signalType,
    String payload,
    String connId,
  ) async {
    try {
      switch (signalType) {
        case _kSigOffer:
          await _handleOffer(peerId, payload, connId, _Lane.general);
        case _kSigAnswer:
          await _handleAnswer(peerId, payload, connId, _Lane.general);
        case _kSigIce:
          await _handleIce(peerId, payload, connId, _Lane.general);
        case _kSigShareOffer:
          await _handleOffer(peerId, payload, connId, _Lane.share);
        case _kSigShareAnswer:
          await _handleAnswer(peerId, payload, connId, _Lane.share);
        case _kSigShareIce:
          await _handleIce(peerId, payload, connId, _Lane.share);
      }
    } catch (e) {
      _log('[HOLLOW-WEBRTC-DART] Signal error ($signalType from $peerId): $e');
    }
  }

  /// Send a file over WebRTC data channel.
  Future<void> sendFile(
    String peerId,
    String transferId,
    String filePath,
    int totalSize,
    String kind,
    int shardIndex, {
    int chunkIndex = 0,
  }) async {
    // Share chunks ride the dedicated STUN-only lane and NEVER fall back to the
    // general (TURN-capable) channel — falling back is the whole bug.
    final lane = kind == 'share_chunk' ? _Lane.share : _Lane.general;
    final conn = _openConnForIdentity(peerId, lane);
    if (conn == null) {
      _log('[HOLLOW-WEBRTC-DART] No ${_tag(lane)} data channel for $peerId, '
          'failing transfer $transferId');
      await _reportTransferFailed(
          transferId, peerId, lane, 'No active data channel');
      return;
    }

    _armIdleTimer(conn, lane);

    try {
      // Read entire file into memory (like WS path) to avoid per-chunk async I/O.
      final fileData = await File(filePath).readAsBytes();
      final dc = conn.dataChannel!;

      final typeFlag = switch (kind) {
        'shard' => _kTypeShard,
        'share_chunk' => _kTypeShareChunk,
        _ => _kTypeFile,
      };
      final idPadded = _padId(transferId);

      // Build and send first chunk. Header layout:
      //   [type:1][id:64][size:8][extra...][data]
      //   extra:  shard      = u16 LE shard_index (2 bytes)
      //           share_chunk = u32 LE chunk_index (4 bytes)
      //           file       = (none)
      final extraLen = switch (kind) {
        'shard' => 2,
        'share_chunk' => 4,
        _ => 0,
      };
      final headerLen = 1 + 64 + 8 + extraLen;
      final firstDataLen = min(_kChunkSize - headerLen, fileData.length);

      final firstChunk = BytesBuilder();
      firstChunk.addByte(typeFlag);
      firstChunk.add(idPadded);
      firstChunk.add(
          (ByteData(8)..setUint64(0, totalSize, Endian.little))
              .buffer
              .asUint8List());
      if (kind == 'shard') {
        firstChunk.add(
            (ByteData(2)..setUint16(0, shardIndex, Endian.little))
                .buffer
                .asUint8List());
      } else if (kind == 'share_chunk') {
        firstChunk.add(
            (ByteData(4)..setUint32(0, chunkIndex, Endian.little))
                .buffer
                .asUint8List());
      }
      firstChunk.add(Uint8List.sublistView(fileData, 0, firstDataLen));
      dc.send(RTCDataChannelMessage.fromBinary(firstChunk.takeBytes()));

      int offset = firstDataLen;

      // Send continuation chunks with proper backpressure via getBufferedAmount().
      // flutter_webrtc 1.4.1 (libwebrtc m144) supports getBufferedAmount() on all
      // platforms including Windows. We send chunks at full speed and only pause
      // when the SCTP send buffer exceeds the threshold.
      while (offset < fileData.length) {
        final contDataLen = min(_kChunkSize - 65, fileData.length - offset);
        final chunk = BytesBuilder();
        chunk.addByte(_kTypeContinuation);
        chunk.add(idPadded);
        chunk.add(Uint8List.sublistView(fileData, offset, offset + contDataLen));
        dc.send(RTCDataChannelMessage.fromBinary(chunk.takeBytes()));

        offset += contDataLen;

        // Backpressure: wait for SCTP buffer to drain if it's getting full.
        var buffered = await dc.getBufferedAmount();
        while (buffered > _kMaxBufferedAmount) {
          await Future.delayed(const Duration(milliseconds: 5));
          buffered = await dc.getBufferedAmount();
        }

        // Sender doesn't need progress — the file is already on disk.
        // Only receiver emits progress (in _onDataChannelMessage).
      }

      // Verify the data channel is still open after sending.
      // dc.send() doesn't throw when the channel is closing — it silently drops bytes.
      if (dc.state != RTCDataChannelState.RTCDataChannelOpen) {
        _log('[HOLLOW-WEBRTC-DART] Data channel died during send of $transferId — triggering WSS fallback');
        await _reportTransferFailed(
            transferId, peerId, lane, 'Data channel closed during send');
        return;
      }

      _armIdleTimer(conn, lane);
      _log('[HOLLOW-WEBRTC-DART] Send complete: $transferId ($offset bytes)');
      onSendComplete?.call(transferId);
      await network_api.webrtcSendComplete(transferId: transferId);
    } catch (e) {
      _log('[HOLLOW-WEBRTC-DART] Send failed: $transferId — $e');
      await _reportTransferFailed(transferId, peerId, lane, e.toString());
    }
  }

  /// Report a failed transfer to Rust on the right lane.
  ///
  /// The general lane's report also evicts the peer from Rust's `webrtc_peers`
  /// and drives the WSS relay retry; the Share lane has its OWN set and no
  /// relay retry (a Share chunk is re-requested by the downloader's scheduler),
  /// so crossing them would knock the general channel out of service over a
  /// Share hiccup — and vice versa.
  Future<void> _reportTransferFailed(
      String transferId, String peerId, _Lane lane, String error) async {
    if (lane == _Lane.share) {
      await network_api.webrtcShareTransferFailed(
        transferId: transferId,
        peerId: peerId,
        error: error,
      );
      return;
    }
    await network_api.webrtcTransferFailed(
      transferId: transferId,
      peerId: peerId,
      error: error,
    );
  }

  /// Send a broadcast file to a peer via data channel (gossip relay tree).
  /// Uses type byte 0x02 with extra broadcast metadata in the header.
  Future<void> sendBroadcast(
    String peerId,
    String broadcastId,
    int ttl,
    String originPeerId,
    String filePath,
    int totalSize,
    String kind,
    int shardIndex,
  ) async {
    // For now, reuse the regular sendFile path — the broadcast metadata
    // (broadcastId, ttl, originPeerId) will be added in the 0x02 header
    // format in a later iteration. Currently, the receiver-side handles
    // broadcast file transfers through the BroadcastMeta MLS envelope,
    // so even without the 0x02 header, the gossip relay works end-to-end
    // because Rust already knows about the broadcast_id via MLS.
    final transferId = '${broadcastId}_$peerId';
    await sendFile(peerId, transferId, filePath, totalSize, kind, shardIndex);
  }

  /// Send a small gossip frame (CRDT op JSON) to a peer: [0x04][payload].
  /// Tier 2 large-server scaling — best-effort by design: Rust only picks
  /// targets it believes are connected, and its relay fallback plus the sync
  /// backstop cover any miss. Returns false if the channel isn't open.
  bool sendGossipOp(String peerId, Uint8List payload) {
    final ch = _connections[peerId]?.dataChannel;
    if (ch == null || ch.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    final frame = Uint8List(payload.length + 1);
    frame[0] = _kTypeGossipOp;
    frame.setRange(1, frame.length, payload);
    ch.send(RTCDataChannelMessage.fromBinary(frame));
    return true;
  }

  /// Close the GENERAL connection to a peer (intentional — no reconnect).
  Future<void> disconnectPeer(String peerId) async {
    _intentionalClose.add(peerId);
    await _cleanupConnection(peerId, _Lane.general);
  }

  /// Close the SHARE connection to a peer (intentional — no reconnect).
  Future<void> disconnectSharePeer(String peerId) async {
    _shareIntentionalClose.add(peerId);
    await _cleanupConnection(peerId, _Lane.share);
  }

  /// Remove and close a peer connection without marking intentional.
  Future<void> _cleanupConnection(String peerId,
      [_Lane lane = _Lane.general]) async {
    _connectingFor(lane).remove(peerId);
    final conn = _connsFor(lane).remove(peerId);
    if (conn != null) await _closeConn(conn);
  }

  /// Tell Rust a lane's data channel is gone. The two sets are separate: the
  /// general one gates file/shard/gossip routing, the Share one gates chunk
  /// scheduling and serving.
  void _notifyDisconnected(String peerId, _Lane lane) {
    if (lane == _Lane.share) {
      network_api.webrtcSharePeerDisconnected(peerId: peerId)
          .catchError((_) {});
      return;
    }
    network_api.webrtcPeerDisconnected(peerId: peerId).catchError((_) {});
  }

  /// Close a single connection's timers + channel + PC WITHOUT touching the
  /// _connections map (the caller owns the map entry — e.g. when superseding an
  /// orphaned connection that's being replaced for the same peer).
  Future<void> _closeConn(_PeerConn conn) async {
    conn.idleTimer?.cancel();
    conn.keepaliveTimer?.cancel();
    try {
      await conn.dataChannel?.close();
    } catch (_) {}
    // close() and dispose() get SEPARATE guards: if close() throws on an
    // already-failing native PC, dispose() (which frees the thread-set) must
    // still run, or the libwebrtc threads leak.
    try {
      await conn.pc.close();
    } catch (_) {}
    try {
      await conn.pc.dispose();
    } catch (_) {}
  }

  /// Dispose all connections (both lanes).
  Future<void> dispose() async {
    final peers = _connections.keys.toList();
    for (final peerId in peers) {
      await disconnectPeer(peerId);
    }
    final sharePeers = _shareConnections.keys.toList();
    for (final peerId in sharePeers) {
      await disconnectSharePeer(peerId);
    }
    // Close any in-flight incoming transfers' IOSinks + delete their temp files
    // before dropping them — clearing the map alone leaks open file handles.
    for (final transfer in _transfers.values) {
      try {
        await transfer.sink.close();
      } catch (_) {}
      try {
        File(transfer.tempPath).deleteSync();
      } catch (_) {}
    }
    _transfers.clear();
    _pendingIceCandidates.clear(); // Phase 6.25 leak fix
    _connecting.clear();
    _shareConnecting.clear();
    _intentionalClose.clear();
    _shareIntentionalClose.clear();
    _shareIceConfig.clear();
    _pingSentAt.clear();
    _screenAudioBufferedCache.clear();
    _screenAudioBufferPolling.clear();
  }

  // --- Private ---

  Future<void> _handleOffer(
      String peerId, String payload, String connId, _Lane lane) async {
    // payload is the raw SDP string (not JSON). On the Share lane, drop any
    // relay candidates the remote inlined before libwebrtc ever sees them.
    final sdp = _stripRelayCandidates(payload, lane);
    final conns = _connsFor(lane);

    // Glare tiebreaker: compare MASTER identities, not raw peer ids. The relay
    // reports DEVICE ids and a multi-device peer can surface as different ids on
    // each side (it offers as its master id; we see its device id), so a raw
    // `localPeerId.compareTo(peerId)` is NOT antisymmetric across the two
    // machines — both can compute "impolite" and neither answers, so the data
    // channel never opens (same device-vs-master deadlock as the Olm glare bug).
    // Resolving both to master makes the ordering identical on both peers.
    final bool politeSelf =
        resolveIdentity(localPeerId).compareTo(resolveIdentity(peerId)) < 0;

    final existing = conns[peerId];
    if (existing != null) {
      // Same connId = renegotiation on existing connection (media track change).
      if (existing.connId == connId) {
        _log('[HOLLOW-WEBRTC-DART] Renegotiation offer from $peerId '
            '(lane=${_tag(lane)}, conn=$connId)');

        // Handle renegotiation glare: if we also sent a renegotiation offer,
        // polite peer rolls back.
        final signalingState = existing.pc.signalingState;
        if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          if (politeSelf) {
            _log('[HOLLOW-WEBRTC-DART] Renegotiation glare: rolling back');
            await existing.pc.setLocalDescription(
                RTCSessionDescription(null, 'rollback'));
          } else {
            _log('[HOLLOW-WEBRTC-DART] Renegotiation glare: ignoring theirs');
            return;
          }
        }

        await existing.pc.setRemoteDescription(
            RTCSessionDescription(sdp, 'offer'));

        final answer = await existing.pc.createAnswer();
        await existing.pc.setLocalDescription(answer);

        await network_api.webrtcSendSignal(
          peerId: peerId,
          signalType: _sigAnswer(lane),
          payload: _stripRelayCandidates(answer.sdp!, lane),
          connId: connId,
        );
        _log('[HOLLOW-WEBRTC-DART] Sent renegotiation answer to $peerId');
        return;
      }

      // Different connId = glare (initial connection collision). Resolved
      // WITHIN the lane — a Share offer must never tear down the general
      // connection (or vice versa); they are independent transports.
      if (politeSelf) {
        _log('[HOLLOW-WEBRTC-DART] Glare (${_tag(lane)}): we are polite, '
            'dropping our connection to $peerId');
        if (lane == _Lane.share) {
          await disconnectSharePeer(peerId);
        } else {
          await disconnectPeer(peerId);
        }
        // Fall through to accept their offer below.
      } else {
        _log('[HOLLOW-WEBRTC-DART] Glare (${_tag(lane)}): we are impolite, '
            'ignoring offer from $peerId');
        return;
      }
    }

    _log('[HOLLOW-WEBRTC-DART] Handling offer from $peerId '
        '(lane=${_tag(lane)}, conn=$connId)');

    // Close any prior connection we still hold for this peer before replacing it
    // in the map — otherwise the old PC's data channel stays open, orphaned (no
    // longer in _connections), and keeps delivering packets (duplicate audio /
    // leaked channel). The glare "polite" branch already disconnected; this
    // covers the non-glare overwrite + reconnect churn.
    final prior = conns[peerId];
    if (prior != null) {
      _log('[HOLLOW-WEBRTC-DART] Replacing prior ${_tag(lane)} connection to '
          '$peerId (closing orphan)');
      // AWAIT — otherwise the orphan's close()/dispose() races the new PC's
      // construction below, leaking the old PC's thread-set (and risking a
      // native teardown overlapping new-PC setup → heap corruption on Linux).
      await _closeConn(prior);
    }

    // A Share offer is ALWAYS answered from the STUN-only Share config — a
    // Share SEEDER mostly answers rather than dials, and answering from the
    // general config would gather TURN candidates and push every uploaded byte
    // through the relay (HOLLOW_PLAN §7A).
    final answerConfig =
        lane == _Lane.share ? _shareConfigFor(peerId) : iceServers;

    final pc = await createPeerConnection(answerConfig);
    final conn = _PeerConn(
      pc: pc,
      connId: connId, // Use THEIR connId — answers must match
      peerId: peerId,
      isOfferer: false,
      lane: lane,
    );
    conns[peerId] = conn;

    // Answer side receives data channel via onDataChannel. Don't call
    // _onDataChannelReady here — _setupDataChannel's onDataChannelState fires it
    // on open (calling it both here AND there double-fires webrtcPeerConnected +
    // starts two keepalive timers).
    pc.onDataChannel = (dc) {
      _log('[HOLLOW-WEBRTC-DART] onDataChannel fired for $peerId '
          '(lane=${_tag(lane)}, label=${dc.label})');
      conn.dataChannel = dc;
      _setupDataChannel(dc, peerId, lane);
    };

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      if (lane == _Lane.share && _isRelayCandidate(candidate.candidate!)) {
        _log('[HOLLOW-WEBRTC-DART] Share: dropping our own relay candidate '
            'for $peerId (should be unreachable — STUN-only config)');
        return;
      }
      final icePayload = jsonEncode({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
      network_api.webrtcSendSignal(
        peerId: peerId,
        signalType: _sigIce(lane),
        payload: icePayload,
        connId: connId,
      );
    };

    pc.onConnectionState = (state) {
      _handleConnectionState(peerId, state, lane);
    };

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    // Send raw SDP string.
    await network_api.webrtcSendSignal(
      peerId: peerId,
      signalType: _sigAnswer(lane),
      payload: _stripRelayCandidates(answer.sdp!, lane),
      connId: connId,
    );
    _log('[HOLLOW-WEBRTC-DART] Sent answer to $peerId '
        '(lane=${_tag(lane)}, conn=$connId)');

    // Flush any ICE candidates that arrived before the offer was processed.
    await _flushPendingIce(connId, lane);
  }

  Future<void> _handleAnswer(
      String peerId, String payload, String connId, _Lane lane) async {
    // Match by peer_id first, then fall back to conn_id. A multi-device peer's
    // answer can arrive tagged with a DIFFERENT device id than the offer was
    // sent to (the relay labels the envelope with whichever device of the
    // peer's identity it routed through), so `_connections[peerId]` misses even
    // though the PC exists. conn_id is the stable, hop-invariant correlator —
    // it's identical in the offer and the answer — so use it to find the PC.
    // Searched within the LANE: the two lanes hold a connection per peer each,
    // and only the conn_id tells them apart.
    var conn = _connsFor(lane)[peerId];
    if (conn == null || conn.connId != connId) {
      final byConn = _findConnByConnId(connId, lane);
      if (byConn != null) conn = byConn;
    }
    if (conn == null) {
      _log('[HOLLOW-WEBRTC-DART] Answer from $peerId but no ${_tag(lane)} '
          'connection exists (conn=$connId)');
      return;
    }

    _log('[HOLLOW-WEBRTC-DART] Handling answer from $peerId (lane=${_tag(lane)}, conn=$connId, ours=${conn.connId}, key=${conn.peerId})');

    if (conn.connId != connId) {
      _log('[HOLLOW-WEBRTC-DART] Ignoring stale answer from $peerId (conn=$connId, current=${conn.connId})');
      return;
    }

    await conn.pc.setRemoteDescription(
        RTCSessionDescription(_stripRelayCandidates(payload, lane), 'answer'));
  }

  /// Find an active connection by its [connId] regardless of which peer_id key
  /// it's stored under. Needed because a multi-device peer's answer/ICE can
  /// arrive labelled with a sibling device id different from the offer target.
  _PeerConn? _findConnByConnId(String connId, [_Lane lane = _Lane.general]) {
    for (final c in _connsFor(lane).values) {
      if (c.connId == connId) return c;
    }
    return null;
  }

  Future<void> _handleIce(
      String peerId, String payload, String connId, _Lane lane) async {
    final json = jsonDecode(payload);
    final candidateStr = json['candidate'] as String;
    // The Share lane is STUN-only by construction on OUR side, but a relay
    // candidate from the REMOTE is still usable by libwebrtc (their TURN
    // allocation, our direct socket) — which would put Share bytes back on the
    // relay. Refuse them: enforcement beats trusting the peer's config.
    if (lane == _Lane.share && _isRelayCandidate(candidateStr)) {
      _log('[HOLLOW-WEBRTC-DART] Share: refused a relay ICE candidate from '
          '$peerId (conn=$connId) — Share stays STUN-only');
      return;
    }
    final candidate = RTCIceCandidate(
      candidateStr,
      json['sdpMid'] as String?,
      json['sdpMLineIndex'] as int?,
    );

    // Match by peer_id, then by conn_id (a sibling-device-labelled candidate for
    // the same PC — see _handleAnswer). Only queue if neither finds the PC.
    var conn = _connsFor(lane)[peerId];
    if (conn == null || conn.connId != connId) {
      final byConn = _findConnByConnId(connId, lane);
      if (byConn != null) conn = byConn;
    }
    if (conn == null) {
      // Queue ICE candidate — the offer/answer handler is still async-processing.
      // Key by conn_id so a sibling-device-labelled candidate still reunites with
      // the right offer once its PC is created (flushed in _flushPendingIce).
      _pendingIceCandidates.putIfAbsent(connId, () => []).add(candidate);
      _log('[HOLLOW-WEBRTC-DART] Queued ICE candidate for $peerId (conn=$connId, no connection yet)');
      return;
    }

    await conn.pc.addCandidate(candidate);
  }

  /// Flush ICE candidates that were queued (by conn_id) before the connection
  /// for [connId] was created.
  Future<void> _flushPendingIce(String connId, [_Lane lane = _Lane.general]) async {
    final queued = _pendingIceCandidates.remove(connId);
    if (queued == null || queued.isEmpty) return;
    final conn = _findConnByConnId(connId, lane);
    if (conn == null) return;
    _log('[HOLLOW-WEBRTC-DART] Flushing ${queued.length} queued ICE candidates for conn=$connId');
    for (final candidate in queued) {
      await conn.pc.addCandidate(candidate);
    }
  }

  void _setupDataChannel(RTCDataChannel dc, String peerId, _Lane lane) {
    dc.onDataChannelState = (state) {
      _log('[HOLLOW-WEBRTC-DART] Data channel state: $peerId '
          '(${_tag(lane)}) -> $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _onDataChannelReady(peerId, lane);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        // Only react to final Closed state, not Closing (prevents double-fire).
        _onDataChannelClosed(peerId, lane);
      }
    };

    dc.onMessage = (msg) {
      _onDataChannelMessage(peerId, msg.binary, lane);
      _resetIdleTimer(peerId, lane);
    };
  }

  void _onDataChannelReady(String peerId, _Lane lane) {
    final conn = _connsFor(lane)[peerId];
    // Idempotency guard: _onDataChannelReady can fire more than once for the
    // same live channel (the answerer's onDataChannel plus onDataChannelState,
    // and reconnect churn), which would double-start the keepalive + re-notify
    // Rust. If this channel already started its keepalive, it's a repeat fire.
    if (conn != null && conn.keepaliveTimer != null) return;

    _log('[HOLLOW-WEBRTC-DART] Data channel OPEN with $peerId '
        '(lane=${_tag(lane)})');
    _resetIdleTimer(peerId, lane);

    // Start keepalive ping to prevent idle timeout. The Share lane keeps it
    // too: while a share is in the registry the tick would re-dial an
    // idled-out link within seconds, so letting it lapse buys nothing but
    // signalling churn.
    if (conn != null) {
      conn.keepaliveTimer?.cancel();
      conn.keepaliveTimer = Timer.periodic(_kKeepaliveInterval, (_) {
        if (conn.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
          _pingSentAt[_pingKey(peerId, lane)] = DateTime.now();
          conn.dataChannel!.send(
              RTCDataChannelMessage.fromBinary(Uint8List.fromList([_kTypePing])));
        }
      });
    }

    if (lane == _Lane.share) {
      network_api.webrtcSharePeerConnected(peerId: peerId).catchError((_) {});
      return;
    }
    network_api.webrtcPeerConnected(peerId: peerId);
  }

  /// RTT bookkeeping key — lane-scoped, or a Share pong would pop the general
  /// lane's timestamp and feed the gossip scorer a bogus round trip.
  String _pingKey(String peerId, _Lane lane) =>
      lane == _Lane.share ? '$peerId#share' : peerId;

  Future<void> _onDataChannelClosed(String peerId, _Lane lane) async {
    _log('[HOLLOW-WEBRTC-DART] Data channel CLOSED with $peerId '
        '(lane=${_tag(lane)})');
    final wasIntentional = _intentionalFor(lane).remove(peerId);
    _pingSentAt.remove(_pingKey(peerId, lane));
    _connectingFor(lane).remove(peerId);
    if (lane == _Lane.general) {
      _screenAudioBufferedCache.remove(peerId);
      _screenAudioBufferPolling.remove(peerId);
    }
    // Route through _closeConn so the PC is actually close()+dispose()'d and
    // BOTH timers (idle + keepalive) are cancelled. Previously this only
    // cancelled idleTimer and dropped the map entry — the RTCPeerConnection
    // (and its libwebrtc thread-set) was orphaned and the keepalive Timer kept
    // firing forever. This is the highest-frequency leak path (every normal
    // disconnect routes here). The map entry is removed first, so the
    // dataChannel.close() inside _closeConn re-entering this callback finds no
    // entry and short-circuits.
    final conn = _connsFor(lane).remove(peerId);
    if (conn != null) {
      await _closeConn(conn);
    }

    // Fail any in-progress incoming transfers from this peer ON THIS LANE —
    // Share chunks ride the Share channel, everything else the general one, so
    // a close on one lane must not cancel the other's transfers.
    final incompleteIds = _transfers.entries
        .where((e) =>
            e.value.senderPeerId == peerId && _laneForKind(e.value.kind) == lane)
        .map((e) => e.key)
        .toList();
    for (final id in incompleteIds) {
      final transfer = _transfers.remove(id);
      if (transfer != null) {
        _log('[HOLLOW-WEBRTC-DART] Incomplete transfer $id from $peerId (${transfer.bytesReceived}/${transfer.totalSize}) — notifying Rust');
        transfer.sink.close();
        try { File(transfer.tempPath).deleteSync(); } catch (_) {}
        _reportTransferFailed(
            id, peerId, lane, 'Data channel closed mid-transfer');
      }
    }

    _notifyDisconnected(peerId, lane);

    if (!wasIntentional) {
      _log('[HOLLOW-WEBRTC-DART] Unexpected close with $peerId — Rust will drive reconnect if needed');
    }
  }

  /// Which lane a transfer of [kind] belongs to.
  static _Lane _laneForKind(String kind) =>
      kind == 'share_chunk' ? _Lane.share : _Lane.general;

  /// Whether a frame type may arrive on [lane]. Continuation frames (0xFF)
  /// carry no type of their own — they're matched against their transfer's
  /// kind at dispatch instead.
  static bool _frameAllowedOnLane(int typeByte, _Lane lane) {
    if (lane == _Lane.share) {
      return typeByte == _kTypeShareChunk || typeByte == _kTypeContinuation;
    }
    return typeByte != _kTypeShareChunk;
  }

  void _handleConnectionState(
      String peerId, RTCPeerConnectionState state, _Lane lane) {
    _log('[HOLLOW-WEBRTC-DART] PC state: $peerId (${_tag(lane)}) -> $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      _logIceRoute(peerId, lane);
    }
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      _log('[HOLLOW-WEBRTC-DART] Connection FAILED with $peerId '
          '(lane=${_tag(lane)}) — closing');
      _cleanupConnection(peerId, lane);
      _notifyDisconnected(peerId, lane);
      if (lane == _Lane.share) {
        // STUN-only and unreachable: no TURN fallback by design (§7A).
        onShareConnectionFailed?.call(peerId);
      }
      // Don't force reconnect here — let _onDataChannelClosed or the share
      // tick (ShareNeedWebRtc) drive reconnection when actually needed.
    }
    // Note: don't close on RTCPeerConnectionStateDisconnected — it can recover.
  }

  Future<void> _logIceRoute(String peerId, _Lane lane) async {
    // Resolve the connection per attempt — glare or a reconnect can swap it
    // out mid-probe, and reporting a route for a superseded PC would feed the
    // gossip scorer a stale verdict.
    final route = await probeIceRoute(() => _connsFor(lane)[peerId]?.pc);
    if (route == null) {
      _log('[HOLLOW-WEBRTC-DART] ICE route to $peerId (${_tag(lane)}): no succeeded candidate pair found');
      return;
    }
    _log('[HOLLOW-WEBRTC-DART] ICE route to $peerId (${_tag(lane)}): $route');
    if (lane == _Lane.share) {
      // A relayed Share route means the §7A guarantee broke somewhere upstream
      // of here — say so loudly rather than quietly burning relay bandwidth.
      if (!route.isDirect) {
        _log('[HOLLOW-WEBRTC-DART] [SENTINEL] Share route to $peerId is NOT '
            'direct ($route) — Share must be STUN-only (HOLLOW_PLAN §7A)');
      }
      // Share routes stay out of the gossip peer scorer: that overlay is built
      // on the general lane.
      return;
    }
    // Tier 3 reachability-aware overlay: feed the route class into the gossip
    // peer scorer so rotation drifts toward direct peers.
    network_api
        .webrtcRouteReport(peerId: peerId, isDirect: route.isDirect)
        .catchError((_) {});
  }

  void _onDataChannelMessage(String peerId, Uint8List data, _Lane lane) {
    if (data.isEmpty) return;

    final typeByte = data[0];

    // Keepalive ping — reply with pong for RTT measurement.
    if (data.length == 1 && typeByte == _kTypePing) {
      final conn = _connsFor(lane)[peerId];
      if (conn?.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
        conn!.dataChannel!.send(
            RTCDataChannelMessage.fromBinary(Uint8List.fromList([_kTypePong])));
      }
      return;
    }

    // Keepalive pong — compute RTT and report to Rust for peer scoring
    // (general lane only; the scorer models the gossip overlay).
    if (data.length == 1 && typeByte == _kTypePong) {
      final sentAt = _pingSentAt.remove(_pingKey(peerId, lane));
      if (sentAt != null && lane == _Lane.general) {
        final rttMs = DateTime.now().difference(sentAt).inMilliseconds;
        network_api.webrtcPingReport(peerId: peerId, rttMs: rttMs);
      }
      return;
    }

    // Lane discipline: the Share channel carries share chunks and nothing else.
    // It is reachable by anyone holding a share link — including people you
    // have no relationship with — so it must not be a way into the file, shard,
    // screen-audio or gossip paths. Symmetrically, share chunks never ride the
    // general channel any more.
    if (!_frameAllowedOnLane(typeByte, lane)) {
      _log('[HOLLOW-WEBRTC-DART] Dropped frame type 0x'
          '${typeByte.toRadixString(16)} on the ${_tag(lane)} lane from $peerId');
      return;
    }

    // Screen audio packet: [0x03][seq:4][opus_data...]
    if (typeByte == _kTypeScreenAudio) {
      if (data.length > 1) {
        if (onScreenAudioReceived != null) {
          onScreenAudioReceived!.call(peerId, data.sublist(1));
        } else {
          _screenAudioMissCount++;
          if (_screenAudioMissCount <= 5) {
            _log('[HOLLOW-AU-SCREEN] RX audio packet but no callback set! (#$_screenAudioMissCount)');
          }
        }
      }
      return;
    }

    // Small gossip frame (Tier 2): [0x04][GossipCrdtOp JSON] — hand to Rust,
    // which validates + applies the op and re-floods it if new.
    if (typeByte == _kTypeGossipOp) {
      if (data.length > 1) {
        network_api
            .webrtcGossipOpReceived(
                senderPeerId: peerId, payload: data.sublist(1))
            .catchError((_) {});
      }
      return;
    }

    if (typeByte == _kTypeContinuation) {
      // Continuation chunk: [0xFF][id:64][payload...]
      if (data.length < 65) return;
      final id = _extractId(data, 1);
      if (id == null) return;
      final transfer = _transfers[id];
      if (transfer == null) return;
      // A continuation must arrive on the same lane its first chunk did.
      if (_laneForKind(transfer.kind) != lane) return;

      final payload = data.sublist(65);
      transfer.sink.add(payload);
      transfer.bytesReceived += payload.length;

      // Receiver-side progress — emit periodically for UI updates.
      if (transfer.bytesReceived - transfer.lastProgressReport >= 512 * 1024
          || transfer.bytesReceived >= transfer.totalSize) {
        onProgress?.call(transfer.transferId, transfer.bytesReceived, transfer.totalSize);
        transfer.lastProgressReport = transfer.bytesReceived;
      }

      if (transfer.bytesReceived >= transfer.totalSize) {
        _completeIncomingTransfer(id);
      }
    } else if (typeByte == _kTypeFile || typeByte == _kTypeShard || typeByte == _kTypeShareChunk) {
      // First chunk: [type:1][id:64][total_size:8][extra...][payload]
      //   extra: shard       = u16 LE shard_index (2 bytes)
      //          share_chunk  = u32 LE chunk_index (4 bytes)
      //          file        = (none)
      if (data.length < 73) return;
      final id = _extractId(data, 1);
      if (id == null) {
        _log('[HOLLOW-WEBRTC-DART] Dropped stream frame from $peerId: '
            'transfer id carries characters outside the allowlist');
        return;
      }
      final totalSize = ByteData.sublistView(data, 65, 73)
          .getUint64(0, Endian.little);

      int payloadStart = 73;
      int shardIndex = 0;
      int chunkIndex = 0;
      String kind;
      if (typeByte == _kTypeShard) {
        if (data.length < 75) return;
        shardIndex =
            ByteData.sublistView(data, 73, 75).getUint16(0, Endian.little);
        payloadStart = 75;
        kind = 'shard';
      } else if (typeByte == _kTypeShareChunk) {
        if (data.length < 77) return;
        chunkIndex =
            ByteData.sublistView(data, 73, 77).getUint32(0, Endian.little);
        payloadStart = 77;
        kind = 'share_chunk';
      } else {
        kind = 'file';
      }

      final filesDir = _getFilesDir();
      // Note: for share_chunk the sender packs chunk_index INTO the id (see sendFile
      // and Rust ws_stream_send) so continuation messages route correctly even
      // with many parallel share chunks in flight. transferId IS already unique.
      final tempPath = '$filesDir/.webrtc_recv_$id.tmp';

      // Fix 4: Discard stale transfer if re-sent (new AES key from re-request).
      if (_transfers.containsKey(id)) {
        final old = _transfers.remove(id);
        if (old != null) {
          old.sink.close();
          try { File(old.tempPath).deleteSync(); } catch (_) {}
          _log('[HOLLOW-WEBRTC-DART] Discarded stale transfer $id (restarting with new key)');
        }
      }

      _log('[HOLLOW-WEBRTC-DART] Receiving $kind $id ($totalSize bytes) from $peerId');

      final file = File(tempPath);
      final sink = file.openWrite();

      final transfer = _IncomingTransfer(
        transferId: id,
        senderPeerId: peerId,
        totalSize: totalSize,
        kind: kind,
        shardIndex: shardIndex,
        chunkIndex: chunkIndex,
        tempPath: tempPath,
        sink: sink,
      );
      _transfers[id] = transfer;

      final payload = data.sublist(payloadStart);
      sink.add(payload);
      transfer.bytesReceived = payload.length;

      // Receiver-side progress for first chunk (Fix 1).
      onProgress?.call(id, transfer.bytesReceived, transfer.totalSize);
      transfer.lastProgressReport = transfer.bytesReceived;

      if (transfer.bytesReceived >= transfer.totalSize) {
        _completeIncomingTransfer(id);
      }
    }
  }

  void _completeIncomingTransfer(String transferId) {
    final transfer = _transfers.remove(transferId);
    if (transfer == null) return;

    // Completion is triggered by the byte COUNTER (bytesReceived >= totalSize),
    // which can fire before the async IOSink has durably flushed the tail to disk —
    // especially when several transfers share Dart's file-I/O thread pool and a
    // large transfer (e.g. an audio file) hogs the queue ahead of a small one.
    // If we signal Rust before the last bytes land, Rust reads a SHORT ciphertext
    // and AES-GCM rejects it (the trailing 16-byte auth tag is missing) → the
    // transfer fails even though the bytes are otherwise fine. So after close(),
    // VERIFY the on-disk length matches totalSize before handing off to Rust.
    transfer.sink.close().then((_) async {
      final ok = await _verifyFlushedSize(transfer.tempPath, transfer.totalSize);
      if (!ok) {
        _log('[HOLLOW-WEBRTC-DART] Receive INCOMPLETE on disk: $transferId '
            '(expected ${transfer.totalSize} bytes) — treating as failed transfer');
        try { File(transfer.tempPath).deleteSync(); } catch (_) {}
        // Signal failure so Rust auto-retries the request (same as a transport drop).
        await _reportTransferFailed(
          transfer.transferId,
          transfer.senderPeerId,
          _laneForKind(transfer.kind),
          'Incomplete on disk (flush verify failed)',
        );
        return;
      }
      _log('[HOLLOW-WEBRTC-DART] Receive complete: $transferId (${transfer.bytesReceived} bytes)');
      onReceiveComplete?.call(
        transfer.transferId,
        transfer.tempPath,
        transfer.senderPeerId,
        transfer.kind,
        transfer.shardIndex,
      );
      if (transfer.kind == 'share_chunk') {
        // Hollow Share routes through a dedicated FFI that carries u32 chunk_index.
        network_api.webrtcShareChunkComplete(
          transferId: transfer.transferId,
          tempPath: transfer.tempPath,
          senderPeerId: transfer.senderPeerId,
          chunkIndex: transfer.chunkIndex,
        );
      } else {
        network_api.webrtcTransferComplete(
          transferId: transfer.transferId,
          tempPath: transfer.tempPath,
          senderPeerId: transfer.senderPeerId,
          kind: transfer.kind,
          shardIndex: transfer.shardIndex,
        );
      }
    });
  }

  /// After sink.close(), the bytes should be flushed — but under concurrent
  /// multi-file I/O the on-disk length can briefly lag. Re-check the file size a
  /// few times with a short backoff before declaring the transfer short. Returns
  /// true if the file reaches at least [expected] bytes.
  Future<bool> _verifyFlushedSize(String path, int expected) async {
    const attempts = 5;
    for (var i = 0; i < attempts; i++) {
      try {
        final len = await File(path).length();
        if (len >= expected) return true;
      } catch (_) {
        // File not visible yet — fall through to retry.
      }
      if (i < attempts - 1) {
        await Future<void>.delayed(Duration(milliseconds: 20 * (i + 1)));
      }
    }
    return false;
  }

  void _resetIdleTimer(String peerId, [_Lane lane = _Lane.general]) {
    final conn = _connsFor(lane)[peerId];
    if (conn == null) return;
    _armIdleTimer(conn, lane);
  }

  /// Arm the idle timer on a specific connection. Takes the connection rather
  /// than a peer id because a send can resolve to a channel keyed under a
  /// SIBLING device id (device<->master collapse) — keying the timer by the
  /// caller's id would leave that channel's timer un-reset.
  void _armIdleTimer(_PeerConn conn, _Lane lane) {
    final key = conn.peerId;
    conn.idleTimer?.cancel();
    conn.idleTimer = Timer(_kIdleTimeout, () {
      _log('[HOLLOW-WEBRTC-DART] Idle timeout for $key (${_tag(lane)})');
      if (lane == _Lane.share) {
        disconnectSharePeer(key);
      } else {
        disconnectPeer(key);
      }
      _notifyDisconnected(key, lane);
    });
  }

  String _generateConnId() {
    final r = Random();
    return List.generate(
            16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Uint8List _padId(String id) {
    final padded = Uint8List(64);
    final bytes = utf8.encode(id);
    final len = min(bytes.length, 64);
    padded.setRange(0, len, bytes);
    return padded;
  }

  /// The id names the temp file, so the parser is the gate: null for any
  /// frame whose id could walk out of the files dir (see wire_transfer_id.dart).
  String? _extractId(Uint8List data, int offset) =>
      parseWireTransferId(data, offset);

  /// Cached files directory path.
  static String? _filesDirCache;
  String _getFilesDir() {
    _filesDirCache ??= _computeFilesDir();
    return _filesDirCache!;
  }

  static String _computeFilesDir() {
    final dir = '$hollowDataDir${Platform.pathSeparator}files';
    Directory(dir).createSync(recursive: true);
    return dir;
  }
}

class _PeerConn {
  final RTCPeerConnection pc;
  RTCDataChannel? dataChannel;
  String connId;
  final String peerId;
  final bool isOfferer;
  final _Lane lane;
  Timer? idleTimer;
  Timer? keepaliveTimer;

  _PeerConn({
    required this.pc,
    required this.connId,
    required this.peerId,
    required this.isOfferer,
    this.lane = _Lane.general,
  });
}

class _IncomingTransfer {
  final String transferId;
  final String senderPeerId;
  final int totalSize;
  final String kind;
  final int shardIndex;
  final int chunkIndex;
  final String tempPath;
  final IOSink sink;
  int bytesReceived = 0;
  int lastProgressReport = 0;

  _IncomingTransfer({
    required this.transferId,
    required this.senderPeerId,
    required this.totalSize,
    required this.kind,
    required this.shardIndex,
    this.chunkIndex = 0,
    required this.tempPath,
    required this.sink,
  });
}

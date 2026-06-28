import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:hollow/src/core/hollow_data_dir.dart';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../rust/api/network.dart' as network_api;

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
const _kTypePing = 0xFE; // keepalive ping byte
const _kTypePong = 0xFC; // keepalive pong response byte

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
  Map<String, dynamic> iceServers;

  /// Active peer connections: peer_id -> _PeerConn
  final Map<String, _PeerConn> _connections = {};

  /// Active incoming transfers: transfer_id -> _IncomingTransfer
  final Map<String, _IncomingTransfer> _transfers = {};

  /// Queued ICE candidates that arrived before the connection was created.
  final Map<String, List<RTCIceCandidate>> _pendingIceCandidates = {};

  /// Callback to request reconnection after a non-idle disconnect.
  void Function(String peerId)? onReconnectNeeded;

  /// Peers we're intentionally closing (idle timeout or manual).
  /// Prevents triggering reconnect for intentional disconnects.
  final Set<String> _intentionalClose = {};

  /// Guards against concurrent connectToPeer calls for the same peer.
  final Set<String> _connecting = {};

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

  /// Peers connected with STUN-only config (Share). Used to fire the right callback on failure.
  final Set<String> _stunOnlyPeers = {};

  WebRtcService({
    required this.localPeerId,
    Map<String, dynamic>? iceServers,
    String relayDomain = 'relay.anonlisten.com',
    String Function(String peerId)? resolveIdentity,
  })  : iceServers = iceServers ?? _defaultIceServers(domain: relayDomain),
        resolveIdentity = resolveIdentity ?? ((p) => p);

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
  _PeerConn? _openConnForIdentity(String peerId) {
    final direct = _connections[peerId];
    if (direct?.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
      return direct;
    }
    final wantId = resolveIdentity(peerId);
    for (final conn in _connections.values) {
      if (conn.dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
        continue;
      }
      if (resolveIdentity(conn.peerId) == wantId) return conn;
    }
    return null;
  }

  /// Check if a peer has an active data channel (device<->master aware).
  bool hasPeerChannel(String peerId) {
    return _openConnForIdentity(peerId) != null;
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
    if (conn == null) {
      final open = _connections.values
          .where((c) =>
              c.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen)
          .toList();
      if (open.length == 1) {
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

  /// Initiate a WebRTC connection to a peer (offerer side).
  /// Pass [iceConfigOverride] to use a specific ICE config (e.g. STUN-only for Share).
  Future<void> connectToPeer(String peerId, {Map<String, dynamic>? iceConfigOverride}) async {
    // Already connected or connecting.
    if (_connections.containsKey(peerId)) return;
    // Already have an OPEN channel to this person under a device id (the caller
    // may pass the MASTER, which isn't a _connections key). Don't open a doomed
    // 2nd connection to the bare master — it has no routable socket and times
    // out. Reuse the existing channel. (Skip this short-circuit for STUN-only
    // Share connections, which intentionally use a separate config.)
    if (iceConfigOverride == null) {
      if (_openConnForIdentity(peerId) != null) return;
      // Cold device-link map: identity didn't resolve, but if there's already
      // exactly one open channel it's this call peer — don't dial the master.
      final openCount = _connections.values
          .where((c) =>
              c.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen)
          .length;
      if (openCount == 1) {
        _log('[HOLLOW-WEBRTC-DART] connectToPeer($peerId): unresolved but one '
            'open channel exists — reusing, not dialing master');
        return;
      }
    }
    if (!_connecting.add(peerId)) return;

    final isStunOnly = iceConfigOverride != null;
    final config = iceConfigOverride ?? iceServers;
    if (isStunOnly) _stunOnlyPeers.add(peerId);
    final connId = _generateConnId();
    _log('[HOLLOW-WEBRTC-DART] Connecting to $peerId (conn=$connId, local=$localPeerId, stunOnly=$isStunOnly)');

    try {
      final pc = await createPeerConnection(config);
      final conn = _PeerConn(
        pc: pc,
        connId: connId,
        peerId: peerId,
        isOfferer: true,
      );
      _connections[peerId] = conn;
      _connecting.remove(peerId);

      // Create data channel (offerer creates it).
      final dcInit = RTCDataChannelInit()
        ..ordered = true;
      final dc = await pc.createDataChannel('hollow-data', dcInit);
      conn.dataChannel = dc;
      _setupDataChannel(dc, peerId);

      // ICE candidate handler.
      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
        final payload = jsonEncode({
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
        network_api.webrtcSendSignal(
          peerId: peerId,
          signalType: 'ice',
          payload: payload,
          connId: conn.connId, // Use current connId (may change on glare)
        );
      };

      // Connection state handler.
      pc.onConnectionState = (state) {
        _handleConnectionState(peerId, state);
      };

      // Create and send offer.
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      // Send raw SDP string (not JSON-wrapped — Rust puts it directly in HavenMessage::RtcOffer.sdp).
      await network_api.webrtcSendSignal(
        peerId: peerId,
        signalType: 'offer',
        payload: offer.sdp!,
        connId: connId,
      );

      // If the data channel doesn't open within 10s, tear down the stale
      // connection so incoming offers or fresh attempts aren't blocked.
      Future.delayed(const Duration(seconds: 10), () {
        final current = _connections[peerId];
        if (current != null && current.connId == connId && !hasPeerChannel(peerId)) {
          _log('[HOLLOW-WEBRTC-DART] Connection timeout for $peerId (conn=$connId) — no data channel opened');
          _cleanupConnection(peerId);
          network_api.webrtcPeerDisconnected(peerId: peerId);
        }
      });
    } catch (e) {
      _connecting.remove(peerId);
      _log('[HOLLOW-WEBRTC-DART] connectToPeer failed for $peerId: $e');
      // A throw after the PC was created+stored (createDataChannel/createOffer/
      // setLocalDescription all throw) leaves a live PC + thread-set in the map.
      // Dispose it — but only if it's still OUR connId (a glare supersede may
      // already have replaced the entry with a newer connection).
      final partial = _connections[peerId];
      if (partial != null && partial.connId == connId) {
        await _cleanupConnection(peerId);
      }
    }
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
        case 'offer':
          await _handleOffer(peerId, payload, connId);
        case 'answer':
          await _handleAnswer(peerId, payload, connId);
        case 'ice':
          await _handleIce(peerId, payload, connId);
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
    final conn = _connections[peerId];
    if (conn == null || !hasPeerChannel(peerId)) {
      _log('[HOLLOW-WEBRTC-DART] No data channel for $peerId, failing transfer $transferId');
      await network_api.webrtcTransferFailed(
        transferId: transferId,
        peerId: peerId,
        error: 'No active data channel',
      );
      return;
    }

    _resetIdleTimer(peerId);

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
        await network_api.webrtcTransferFailed(
          transferId: transferId,
          peerId: peerId,
          error: 'Data channel closed during send',
        );
        return;
      }

      _resetIdleTimer(peerId);
      _log('[HOLLOW-WEBRTC-DART] Send complete: $transferId ($offset bytes)');
      onSendComplete?.call(transferId);
      await network_api.webrtcSendComplete(transferId: transferId);
    } catch (e) {
      _log('[HOLLOW-WEBRTC-DART] Send failed: $transferId — $e');
      await network_api.webrtcTransferFailed(
        transferId: transferId,
        peerId: peerId,
        error: e.toString(),
      );
    }
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

  /// Close connection to a peer (intentional — no reconnect).
  Future<void> disconnectPeer(String peerId) async {
    _intentionalClose.add(peerId);
    await _cleanupConnection(peerId);
  }

  /// Remove and close a peer connection without marking intentional.
  Future<void> _cleanupConnection(String peerId) async {
    _connecting.remove(peerId);
    _stunOnlyPeers.remove(peerId);
    final conn = _connections.remove(peerId);
    if (conn != null) await _closeConn(conn);
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

  /// Dispose all connections.
  Future<void> dispose() async {
    final peers = _connections.keys.toList();
    for (final peerId in peers) {
      await disconnectPeer(peerId);
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
    _intentionalClose.clear();
    _stunOnlyPeers.clear();
    _pingSentAt.clear();
    _screenAudioBufferedCache.clear();
    _screenAudioBufferPolling.clear();
  }

  // --- Private ---

  Future<void> _handleOffer(
      String peerId, String payload, String connId) async {
    // payload is the raw SDP string (not JSON).
    final sdp = payload;

    // Glare tiebreaker: compare MASTER identities, not raw peer ids. The relay
    // reports DEVICE ids and a multi-device peer can surface as different ids on
    // each side (it offers as its master id; we see its device id), so a raw
    // `localPeerId.compareTo(peerId)` is NOT antisymmetric across the two
    // machines — both can compute "impolite" and neither answers, so the data
    // channel never opens (same device-vs-master deadlock as the Olm glare bug).
    // Resolving both to master makes the ordering identical on both peers.
    final bool politeSelf =
        resolveIdentity(localPeerId).compareTo(resolveIdentity(peerId)) < 0;

    final existing = _connections[peerId];
    if (existing != null) {
      // Same connId = renegotiation on existing connection (media track change).
      if (existing.connId == connId) {
        _log('[HOLLOW-WEBRTC-DART] Renegotiation offer from $peerId (conn=$connId)');

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
          signalType: 'answer',
          payload: answer.sdp!,
          connId: connId,
        );
        _log('[HOLLOW-WEBRTC-DART] Sent renegotiation answer to $peerId');
        return;
      }

      // Different connId = glare (initial connection collision).
      if (politeSelf) {
        _log('[HOLLOW-WEBRTC-DART] Glare: we are polite, dropping our connection to $peerId');
        await disconnectPeer(peerId);
        // Fall through to accept their offer below.
      } else {
        _log('[HOLLOW-WEBRTC-DART] Glare: we are impolite, ignoring offer from $peerId');
        return;
      }
    }

    _log('[HOLLOW-WEBRTC-DART] Handling offer from $peerId (conn=$connId)');

    // Close any prior connection we still hold for this peer before replacing it
    // in the map — otherwise the old PC's data channel stays open, orphaned (no
    // longer in _connections), and keeps delivering packets (duplicate audio /
    // leaked channel). The glare "polite" branch already disconnected; this
    // covers the non-glare overwrite + reconnect churn.
    final prior = _connections[peerId];
    if (prior != null) {
      _log('[HOLLOW-WEBRTC-DART] Replacing prior connection to $peerId (closing orphan)');
      // AWAIT — otherwise the orphan's close()/dispose() races the new PC's
      // construction below, leaking the old PC's thread-set (and risking a
      // native teardown overlapping new-PC setup → heap corruption on Linux).
      await _closeConn(prior);
    }

    final pc = await createPeerConnection(iceServers);
    final conn = _PeerConn(
      pc: pc,
      connId: connId, // Use THEIR connId — answers must match
      peerId: peerId,
      isOfferer: false,
    );
    _connections[peerId] = conn;

    // Answer side receives data channel via onDataChannel. Don't call
    // _onDataChannelReady here — _setupDataChannel's onDataChannelState fires it
    // on open (calling it both here AND there double-fires webrtcPeerConnected +
    // starts two keepalive timers).
    pc.onDataChannel = (dc) {
      _log('[HOLLOW-WEBRTC-DART] onDataChannel fired for $peerId');
      conn.dataChannel = dc;
      _setupDataChannel(dc, peerId);
    };

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      final icePayload = jsonEncode({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
      network_api.webrtcSendSignal(
        peerId: peerId,
        signalType: 'ice',
        payload: icePayload,
        connId: connId,
      );
    };

    pc.onConnectionState = (state) {
      _handleConnectionState(peerId, state);
    };

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);

    // Send raw SDP string.
    await network_api.webrtcSendSignal(
      peerId: peerId,
      signalType: 'answer',
      payload: answer.sdp!,
      connId: connId,
    );
    _log('[HOLLOW-WEBRTC-DART] Sent answer to $peerId (conn=$connId)');

    // Flush any ICE candidates that arrived before the offer was processed.
    await _flushPendingIce(connId);
  }

  Future<void> _handleAnswer(
      String peerId, String payload, String connId) async {
    // Match by peer_id first, then fall back to conn_id. A multi-device peer's
    // answer can arrive tagged with a DIFFERENT device id than the offer was
    // sent to (the relay labels the envelope with whichever device of the
    // peer's identity it routed through), so `_connections[peerId]` misses even
    // though the PC exists. conn_id is the stable, hop-invariant correlator —
    // it's identical in the offer and the answer — so use it to find the PC.
    var conn = _connections[peerId];
    if (conn == null || conn.connId != connId) {
      final byConn = _findConnByConnId(connId);
      if (byConn != null) conn = byConn;
    }
    if (conn == null) {
      _log('[HOLLOW-WEBRTC-DART] Answer from $peerId but no connection exists (conn=$connId)');
      return;
    }

    _log('[HOLLOW-WEBRTC-DART] Handling answer from $peerId (conn=$connId, ours=${conn.connId}, key=${conn.peerId})');

    if (conn.connId != connId) {
      _log('[HOLLOW-WEBRTC-DART] Ignoring stale answer from $peerId (conn=$connId, current=${conn.connId})');
      return;
    }

    await conn.pc.setRemoteDescription(RTCSessionDescription(payload, 'answer'));
  }

  /// Find an active connection by its [connId] regardless of which peer_id key
  /// it's stored under. Needed because a multi-device peer's answer/ICE can
  /// arrive labelled with a sibling device id different from the offer target.
  _PeerConn? _findConnByConnId(String connId) {
    for (final c in _connections.values) {
      if (c.connId == connId) return c;
    }
    return null;
  }

  Future<void> _handleIce(
      String peerId, String payload, String connId) async {
    final json = jsonDecode(payload);
    final candidate = RTCIceCandidate(
      json['candidate'] as String,
      json['sdpMid'] as String?,
      json['sdpMLineIndex'] as int?,
    );

    // Match by peer_id, then by conn_id (a sibling-device-labelled candidate for
    // the same PC — see _handleAnswer). Only queue if neither finds the PC.
    var conn = _connections[peerId];
    if (conn == null || conn.connId != connId) {
      final byConn = _findConnByConnId(connId);
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
  Future<void> _flushPendingIce(String connId) async {
    final queued = _pendingIceCandidates.remove(connId);
    if (queued == null || queued.isEmpty) return;
    final conn = _findConnByConnId(connId);
    if (conn == null) return;
    _log('[HOLLOW-WEBRTC-DART] Flushing ${queued.length} queued ICE candidates for conn=$connId');
    for (final candidate in queued) {
      await conn.pc.addCandidate(candidate);
    }
  }

  void _setupDataChannel(RTCDataChannel dc, String peerId) {
    dc.onDataChannelState = (state) {
      _log('[HOLLOW-WEBRTC-DART] Data channel state: $peerId -> $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _onDataChannelReady(peerId);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        // Only react to final Closed state, not Closing (prevents double-fire).
        _onDataChannelClosed(peerId);
      }
    };

    dc.onMessage = (msg) {
      _onDataChannelMessage(peerId, msg.binary);
      _resetIdleTimer(peerId);
    };
  }

  void _onDataChannelReady(String peerId) {
    final conn = _connections[peerId];
    // Idempotency guard: _onDataChannelReady can fire more than once for the
    // same live channel (the answerer's onDataChannel plus onDataChannelState,
    // and reconnect churn), which would double-start the keepalive + re-notify
    // Rust. If this channel already started its keepalive, it's a repeat fire.
    if (conn != null && conn.keepaliveTimer != null) return;

    _log('[HOLLOW-WEBRTC-DART] Data channel OPEN with $peerId');
    _resetIdleTimer(peerId);

    // Start keepalive ping to prevent idle timeout.
    if (conn != null) {
      conn.keepaliveTimer?.cancel();
      conn.keepaliveTimer = Timer.periodic(_kKeepaliveInterval, (_) {
        if (conn.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
          _pingSentAt[peerId] = DateTime.now();
          conn.dataChannel!.send(
              RTCDataChannelMessage.fromBinary(Uint8List.fromList([_kTypePing])));
        }
      });
    }

    network_api.webrtcPeerConnected(peerId: peerId);
  }

  Future<void> _onDataChannelClosed(String peerId) async {
    _log('[HOLLOW-WEBRTC-DART] Data channel CLOSED with $peerId');
    final wasIntentional = _intentionalClose.remove(peerId);
    _pingSentAt.remove(peerId);
    _screenAudioBufferedCache.remove(peerId);
    _screenAudioBufferPolling.remove(peerId);
    _connecting.remove(peerId);
    _stunOnlyPeers.remove(peerId);
    // Route through _closeConn so the PC is actually close()+dispose()'d and
    // BOTH timers (idle + keepalive) are cancelled. Previously this only
    // cancelled idleTimer and dropped the map entry — the RTCPeerConnection
    // (and its libwebrtc thread-set) was orphaned and the keepalive Timer kept
    // firing forever. This is the highest-frequency leak path (every normal
    // disconnect routes here). The map entry is removed first, so the
    // dataChannel.close() inside _closeConn re-entering this callback finds no
    // entry and short-circuits.
    final conn = _connections.remove(peerId);
    if (conn != null) {
      await _closeConn(conn);
    }

    // Fail any in-progress incoming transfers from this peer.
    final incompleteIds = _transfers.entries
        .where((e) => e.value.senderPeerId == peerId)
        .map((e) => e.key)
        .toList();
    for (final id in incompleteIds) {
      final transfer = _transfers.remove(id);
      if (transfer != null) {
        _log('[HOLLOW-WEBRTC-DART] Incomplete transfer $id from $peerId (${transfer.bytesReceived}/${transfer.totalSize}) — notifying Rust');
        transfer.sink.close();
        try { File(transfer.tempPath).deleteSync(); } catch (_) {}
        network_api.webrtcTransferFailed(
          transferId: id,
          peerId: peerId,
          error: 'Data channel closed mid-transfer',
        );
      }
    }

    network_api.webrtcPeerDisconnected(peerId: peerId);

    if (!wasIntentional) {
      _log('[HOLLOW-WEBRTC-DART] Unexpected close with $peerId — Rust will drive reconnect if needed');
    }
  }

  void _handleConnectionState(
      String peerId, RTCPeerConnectionState state) {
    _log('[HOLLOW-WEBRTC-DART] PC state: $peerId -> $state');
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      Future.delayed(const Duration(seconds: 1), () => _logIceRoute(peerId));
    }
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      final wasStunOnly = _stunOnlyPeers.remove(peerId);
      _log('[HOLLOW-WEBRTC-DART] Connection FAILED with $peerId — closing (stunOnly=$wasStunOnly)');
      _cleanupConnection(peerId);
      network_api.webrtcPeerDisconnected(peerId: peerId);
      if (wasStunOnly) {
        onShareConnectionFailed?.call(peerId);
      }
      // Don't force reconnect here — let _onDataChannelClosed or the share
      // tick (ShareNeedWebRtc) drive reconnection when actually needed.
    }
    // Note: don't close on RTCPeerConnectionStateDisconnected — it can recover.
  }

  Future<void> _logIceRoute(String peerId) async {
    final conn = _connections[peerId];
    if (conn == null) return;
    try {
      final stats = await conn.pc.getStats();
      for (final report in stats) {
        if (report.type == 'candidate-pair' &&
            report.values['state'] == 'succeeded') {
          final localId = report.values['localCandidateId'] as String?;
          final remoteId = report.values['remoteCandidateId'] as String?;
          String localType = '?';
          String remoteType = '?';
          String localProto = '';
          for (final r in stats) {
            if (r.type == 'local-candidate' && r.id == localId) {
              localType = (r.values['candidateType'] as String?) ?? '?';
              localProto = (r.values['protocol'] as String?) ?? '';
            }
            if (r.type == 'remote-candidate' && r.id == remoteId) {
              remoteType = (r.values['candidateType'] as String?) ?? '?';
            }
          }
          final route = localType == 'relay' || remoteType == 'relay'
              ? 'TURN (relayed)'
              : localType == 'srflx' || remoteType == 'srflx'
                  ? 'STUN (direct P2P)'
                  : localType == 'host' && remoteType == 'host'
                      ? 'LAN (direct)'
                      : 'P2P ($localType/$remoteType)';
          _log('[HOLLOW-WEBRTC-DART] ICE route to $peerId: $route (local=$localType remote=$remoteType proto=$localProto)');
          return;
        }
      }
      _log('[HOLLOW-WEBRTC-DART] ICE route to $peerId: no succeeded candidate pair found');
    } catch (e) {
      _log('[HOLLOW-WEBRTC-DART] ICE route check failed for $peerId: $e');
    }
  }

  void _onDataChannelMessage(String peerId, Uint8List data) {
    if (data.isEmpty) return;

    final typeByte = data[0];

    // Keepalive ping — reply with pong for RTT measurement.
    if (data.length == 1 && typeByte == _kTypePing) {
      final conn = _connections[peerId];
      if (conn?.dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
        conn!.dataChannel!.send(
            RTCDataChannelMessage.fromBinary(Uint8List.fromList([_kTypePong])));
      }
      return;
    }

    // Keepalive pong — compute RTT and report to Rust for peer scoring.
    if (data.length == 1 && typeByte == _kTypePong) {
      final sentAt = _pingSentAt.remove(peerId);
      if (sentAt != null) {
        final rttMs = DateTime.now().difference(sentAt).inMilliseconds;
        network_api.webrtcPingReport(peerId: peerId, rttMs: rttMs);
      }
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

    if (typeByte == _kTypeContinuation) {
      // Continuation chunk: [0xFF][id:64][payload...]
      if (data.length < 65) return;
      final id = _extractId(data, 1);
      final transfer = _transfers[id];
      if (transfer == null) return;

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
        network_api.webrtcTransferFailed(
          transferId: transfer.transferId,
          peerId: transfer.senderPeerId,
          error: 'Incomplete on disk (flush verify failed)',
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

  void _resetIdleTimer(String peerId) {
    final conn = _connections[peerId];
    if (conn == null) return;
    conn.idleTimer?.cancel();
    conn.idleTimer = Timer(_kIdleTimeout, () {
      _log('[HOLLOW-WEBRTC-DART] Idle timeout for $peerId');
      disconnectPeer(peerId);
      network_api.webrtcPeerDisconnected(peerId: peerId);
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

  String _extractId(Uint8List data, int offset) {
    final idBytes = data.sublist(offset, offset + 64);
    final nulIndex = idBytes.indexOf(0);
    final len = nulIndex == -1 ? 64 : nulIndex;
    return utf8.decode(idBytes.sublist(0, len));
  }

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
  Timer? idleTimer;
  Timer? keepaliveTimer;

  _PeerConn({
    required this.pc,
    required this.connId,
    required this.peerId,
    required this.isOfferer,
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

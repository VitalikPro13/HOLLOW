import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

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
const _kTypePing = 0xFE; // keepalive ping byte
const _kTypePong = 0xFC; // keepalive pong response byte

/// Idle timeout before closing a peer connection (3x keepalive interval).
const _kIdleTimeout = Duration(seconds: 90);

/// Keepalive ping interval — keeps the data channel alive.
const _kKeepaliveInterval = Duration(seconds: 30);

/// Default ICE servers (STUN only — used if no config injected).
final _defaultIceServers = {
  'iceServers': [
    {'urls': 'stun:relay.anonlisten.com:3478'},
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

  WebRtcService({required this.localPeerId, Map<String, dynamic>? iceServers})
      : iceServers = iceServers ?? _defaultIceServers;

  /// Check if a peer has an active data channel.
  bool hasPeerChannel(String peerId) {
    final conn = _connections[peerId];
    return conn != null &&
        conn.dataChannel != null &&
        conn.dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen;
  }

  /// Initiate a WebRTC connection to a peer (offerer side).
  Future<void> connectToPeer(String peerId) async {
    // Already connected or connecting.
    if (_connections.containsKey(peerId)) return;
    if (!_connecting.add(peerId)) return;

    final connId = _generateConnId();
    _log('[HOLLOW-WEBRTC-DART] Connecting to $peerId (conn=$connId, local=$localPeerId)');

    try {
      final pc = await createPeerConnection(iceServers);
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
          await Future.delayed(const Duration(milliseconds: 1));
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
    final conn = _connections.remove(peerId);
    if (conn != null) {
      conn.idleTimer?.cancel();
      conn.keepaliveTimer?.cancel();
      try {
        await conn.dataChannel?.close();
      } catch (_) {}
      try {
        await conn.pc.close();
        await conn.pc.dispose();
      } catch (_) {}
    }
  }

  /// Dispose all connections.
  Future<void> dispose() async {
    final peers = _connections.keys.toList();
    for (final peerId in peers) {
      await disconnectPeer(peerId);
    }
    _transfers.clear();
    _pendingIceCandidates.clear(); // Phase 6.25 leak fix
    _connecting.clear();
  }

  // --- Private ---

  Future<void> _handleOffer(
      String peerId, String payload, String connId) async {
    // payload is the raw SDP string (not JSON).
    final sdp = payload;

    final existing = _connections[peerId];
    if (existing != null) {
      // Same connId = renegotiation on existing connection (media track change).
      if (existing.connId == connId) {
        _log('[HOLLOW-WEBRTC-DART] Renegotiation offer from $peerId (conn=$connId)');

        // Handle renegotiation glare: if we also sent a renegotiation offer,
        // polite peer rolls back.
        final signalingState = existing.pc.signalingState;
        if (signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
          if (localPeerId.compareTo(peerId) < 0) {
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
      if (localPeerId.compareTo(peerId) < 0) {
        _log('[HOLLOW-WEBRTC-DART] Glare: we are polite, dropping our connection to $peerId');
        await disconnectPeer(peerId);
        // Fall through to accept their offer below.
      } else {
        _log('[HOLLOW-WEBRTC-DART] Glare: we are impolite, ignoring offer from $peerId');
        return;
      }
    }

    _log('[HOLLOW-WEBRTC-DART] Handling offer from $peerId (conn=$connId)');

    final pc = await createPeerConnection(iceServers);
    final conn = _PeerConn(
      pc: pc,
      connId: connId, // Use THEIR connId — answers must match
      peerId: peerId,
      isOfferer: false,
    );
    _connections[peerId] = conn;

    // Answer side receives data channel via onDataChannel.
    pc.onDataChannel = (dc) {
      _log('[HOLLOW-WEBRTC-DART] onDataChannel fired for $peerId');
      conn.dataChannel = dc;
      _setupDataChannel(dc, peerId);
      _onDataChannelReady(peerId);
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
    await _flushPendingIce(peerId);
  }

  Future<void> _handleAnswer(
      String peerId, String payload, String connId) async {
    final conn = _connections[peerId];
    if (conn == null) {
      _log('[HOLLOW-WEBRTC-DART] Answer from $peerId but no connection exists');
      return;
    }

    _log('[HOLLOW-WEBRTC-DART] Handling answer from $peerId (conn=$connId, ours=${conn.connId})');

    if (conn.connId != connId) {
      _log('[HOLLOW-WEBRTC-DART] Ignoring stale answer from $peerId (conn=$connId, current=${conn.connId})');
      return;
    }

    await conn.pc.setRemoteDescription(RTCSessionDescription(payload, 'answer'));
  }

  Future<void> _handleIce(
      String peerId, String payload, String connId) async {
    final json = jsonDecode(payload);
    final candidate = RTCIceCandidate(
      json['candidate'] as String,
      json['sdpMid'] as String?,
      json['sdpMLineIndex'] as int?,
    );

    final conn = _connections[peerId];
    if (conn == null) {
      // Queue ICE candidate — the offer/answer handler is still async-processing.
      _pendingIceCandidates.putIfAbsent(peerId, () => []).add(candidate);
      _log('[HOLLOW-WEBRTC-DART] Queued ICE candidate for $peerId (no connection yet)');
      return;
    }

    await conn.pc.addCandidate(candidate);
  }

  /// Flush any ICE candidates that were queued before the connection was created.
  Future<void> _flushPendingIce(String peerId) async {
    final queued = _pendingIceCandidates.remove(peerId);
    if (queued == null || queued.isEmpty) return;
    final conn = _connections[peerId];
    if (conn == null) return;
    _log('[HOLLOW-WEBRTC-DART] Flushing ${queued.length} queued ICE candidates for $peerId');
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
    _log('[HOLLOW-WEBRTC-DART] Data channel OPEN with $peerId');
    _resetIdleTimer(peerId);

    // Start keepalive ping to prevent idle timeout.
    final conn = _connections[peerId];
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

  void _onDataChannelClosed(String peerId) {
    _log('[HOLLOW-WEBRTC-DART] Data channel CLOSED with $peerId');
    final wasIntentional = _intentionalClose.remove(peerId);
    _pingSentAt.remove(peerId);
    _connections[peerId]?.idleTimer?.cancel();
    _connections.remove(peerId);

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
    if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
      _log('[HOLLOW-WEBRTC-DART] Connection FAILED with $peerId — closing');
      _cleanupConnection(peerId);
      network_api.webrtcPeerDisconnected(peerId: peerId);
      // Don't force reconnect here — let _onDataChannelClosed or the share
      // tick (ShareNeedWebRtc) drive reconnection when actually needed.
    }
    // Note: don't close on RTCPeerConnectionStateDisconnected — it can recover.
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

    transfer.sink.close().then((_) {
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
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    final hollowDataDir = Platform.environment['HOLLOW_DATA_DIR'];
    if (hollowDataDir != null && hollowDataDir.isNotEmpty) {
      final dir = '$hollowDataDir/files';
      Directory(dir).createSync(recursive: true);
      return dir;
    }
    final dir = '$home/.hollow/files';
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

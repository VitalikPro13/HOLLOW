import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Per-peer WebRTC connection status.
enum WebRtcPeerStatus { connecting, connected, failed }

/// State of all WebRTC connections.
class WebRtcState {
  final Map<String, WebRtcPeerStatus> peers;
  const WebRtcState({this.peers = const {}});

  WebRtcState copyWith({Map<String, WebRtcPeerStatus>? peers}) =>
      WebRtcState(peers: peers ?? this.peers);
}

class WebRtcNotifier extends Notifier<WebRtcState> {
  WebRtcService? _service;

  WebRtcService get service {
    if (_service == null) {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final iceConfig = ref.read(iceConfigProvider);
      final relayDomain = ref.read(relayDomainProvider);
      _service = WebRtcService(
        localPeerId: localPeerId,
        iceServers: iceConfig,
        relayDomain: relayDomain,
        // Live device→master resolver for the glare tiebreaker (multi-device).
        // Read on each call so it reflects the latest device-link mirror.
        resolveIdentity: (id) => ref.read(deviceLinkProvider).identityOf(id),
      );
      _wireCallbacks();
    } else {
      // Keep ICE config up to date (TURN credentials refresh).
      _service!.iceServers = ref.read(iceConfigProvider);
    }
    return _service!;
  }

  @override
  WebRtcState build() => const WebRtcState();

  void _wireCallbacks() {
    _service!.onProgress = (transferId, bytesDone, totalBytes) {
      // Pass raw byte counts as "chunks" — the widget uses the ratio
      // (chunksReceived / totalChunks) for the progress bar, so raw bytes work.
      // Clamp to prevent overshoot (ciphertext is slightly larger than plaintext).
      final clamped = bytesDone.clamp(0, totalBytes);
      ref.read(fileTransferProvider.notifier).onFileProgress(
            transferId,
            clamped,
            totalBytes,
          );
    };

    _service!.onSendComplete = (transferId) {
      debugPrint('[HOLLOW-WEBRTC] Provider: send complete $transferId');
    };

    _service!.onReceiveComplete =
        (transferId, tempPath, senderPeerId, kind, shardIndex) {
      debugPrint(
          '[HOLLOW-WEBRTC] Provider: receive complete $transferId at $tempPath');
      // Rust handles the rest via webrtcTransferComplete FFI call
      // (called by WebRtcService already).
    };

    _service!.onReconnectNeeded = (peerId) {
      // Re-establish WebRTC connection after unexpected close (e.g., buffer crash).
      // Delay slightly to let the old connection fully clean up.
      Future.delayed(const Duration(seconds: 2), () {
        ensureConnection(peerId);
      });
    };

    _service!.onShareConnectionFailed = (peerId) {
      final short = peerId.length > 12 ? '${peerId.substring(0, 12)}...' : peerId;
      debugPrint('[HOLLOW-SHARE] STUN-only connection failed to $peerId — peer unreachable without TURN');
      final ctx = hollowNavigatorKey.currentContext;
      if (ctx != null) {
        HollowToast.show(
          ctx,
          'Share: peer $short unreachable (strict NAT)',
          type: HollowToastType.error,
        );
      }
    };
  }

  /// Handle incoming signaling message from Rust event.
  Future<void> handleSignal(
      String peerId, String signalType, String payload, String connId) async {
    final s = service;
    // Update state to show connecting.
    final peers = Map<String, WebRtcPeerStatus>.from(state.peers);
    if (!peers.containsKey(peerId)) {
      peers[peerId] = WebRtcPeerStatus.connecting;
      state = state.copyWith(peers: peers);
    }
    await s.handleSignal(peerId, signalType, payload, connId);
  }

  /// Handle WebRtcSendFile event from Rust.
  Future<void> handleSendFile(String peerId, String transferId,
      String filePath, int totalSize, String kind, int shardIndex,
      {int chunkIndex = 0}) async {
    await service.sendFile(
        peerId, transferId, filePath, totalSize, kind, shardIndex,
        chunkIndex: chunkIndex);
  }

  /// Proactively establish WebRTC connection to a peer.
  /// Pass [iceConfigOverride] for STUN-only connections (e.g. Share).
  Future<void> ensureConnection(String peerId, {Map<String, dynamic>? iceConfigOverride}) async {
    final s = service;
    // Register the Share peer even when we don't dial — a Share SEEDER usually
    // ends up answering the downloader's offer, and the answer path needs the
    // STUN-only config so Share bytes never ride the relay.
    if (iceConfigOverride != null) {
      s.noteShareIceConfig(peerId, iceConfigOverride);
    }
    if (s.hasPeerChannel(peerId)) return;
    final peers = Map<String, WebRtcPeerStatus>.from(state.peers);
    peers[peerId] = WebRtcPeerStatus.connecting;
    state = state.copyWith(peers: peers);
    await s.connectToPeer(peerId, iceConfigOverride: iceConfigOverride);
  }

  /// Mark peer as connected (called when data channel opens).
  void onPeerConnected(String peerId) {
    final peers = Map<String, WebRtcPeerStatus>.from(state.peers);
    peers[peerId] = WebRtcPeerStatus.connected;
    state = state.copyWith(peers: peers);
  }

  /// Clean up a peer's connection.
  Future<void> disconnectPeer(String peerId) async {
    _service?.disconnectPeer(peerId);
    final peers = Map<String, WebRtcPeerStatus>.from(state.peers);
    peers.remove(peerId);
    state = state.copyWith(peers: peers);
  }

  /// Relay a broadcast file to gossip neighbors via data channels.
  Future<void> relayBroadcast({
    required String broadcastId,
    required int ttl,
    required String originPeerId,
    required String filePath,
    required int totalSize,
    required String kind,
    required int shardIndex,
    required String excludePeerId,
  }) async {
    final s = service;
    // Send the broadcast to all connected gossip neighbors (Rust already
    // filtered to the right set and excluded the sender).
    for (final entry in state.peers.entries) {
      if (entry.value == WebRtcPeerStatus.connected &&
          entry.key != excludePeerId) {
        await s.sendBroadcast(
          entry.key,
          broadcastId,
          ttl,
          originPeerId,
          filePath,
          totalSize,
          kind,
          shardIndex,
        );
      }
    }
  }

  /// Send a small gossip CRDT-op frame to mesh targets (Tier 2 scaling).
  /// Rust already picked connected neighbors; a closed channel just skips
  /// (its relay fallback + sync backstop cover the miss).
  void relayGossipOp({required List<String> targets, required Uint8List payload}) {
    final s = service;
    for (final target in targets) {
      s.sendGossipOp(target, payload);
    }
  }

  /// Dispose all connections (app shutdown).
  Future<void> disposeAll() async {
    await _service?.dispose();
    state = const WebRtcState();
  }
}

final webRtcProvider =
    NotifierProvider<WebRtcNotifier, WebRtcState>(WebRtcNotifier.new);

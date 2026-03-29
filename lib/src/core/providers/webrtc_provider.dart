import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/services/webrtc_service.dart';

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
      _service = WebRtcService(localPeerId: localPeerId);
      _wireCallbacks();
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
      String filePath, int totalSize, String kind, int shardIndex) async {
    await service.sendFile(
        peerId, transferId, filePath, totalSize, kind, shardIndex);
  }

  /// Proactively establish WebRTC connection to a peer.
  Future<void> ensureConnection(String peerId) async {
    final s = service;
    if (s.hasPeerChannel(peerId)) return;
    final peers = Map<String, WebRtcPeerStatus>.from(state.peers);
    peers[peerId] = WebRtcPeerStatus.connecting;
    state = state.copyWith(peers: peers);
    await s.connectToPeer(peerId);
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

  /// Dispose all connections (app shutdown).
  Future<void> disposeAll() async {
    await _service?.dispose();
    state = const WebRtcState();
  }
}

final webRtcProvider =
    NotifierProvider<WebRtcNotifier, WebRtcState>(WebRtcNotifier.new);

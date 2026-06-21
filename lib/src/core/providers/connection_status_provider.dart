import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/node_provider.dart';

/// Granular connection stage for a peer.
enum PeerConnectionStage {
  dialing,
  connected,
  keyExchange,
  encrypted,
  failed,
}

/// Per-peer connection status with detail.
class PeerConnectionStatus {
  final String peerId;
  final PeerConnectionStage stage;
  final String? method;
  final String? detail;
  final String? failReason;
  final DateTime lastUpdated;

  const PeerConnectionStatus({
    required this.peerId,
    required this.stage,
    this.method,
    this.detail,
    this.failReason,
    required this.lastUpdated,
  });

  PeerConnectionStatus copyWith({
    PeerConnectionStage? stage,
    String? Function()? method,
    String? Function()? detail,
    String? Function()? failReason,
  }) {
    return PeerConnectionStatus(
      peerId: peerId,
      stage: stage ?? this.stage,
      method: method != null ? method() : this.method,
      detail: detail != null ? detail() : this.detail,
      failReason: failReason != null ? failReason() : this.failReason,
      lastUpdated: DateTime.now(),
    );
  }

  /// Human-readable status label for the UI.
  String get label {
    return switch (stage) {
      PeerConnectionStage.dialing => 'Connecting...',
      PeerConnectionStage.connected => 'Connected',
      PeerConnectionStage.keyExchange => switch (detail) {
          'key_request_sent' => 'Requesting keys...',
          'session_created' => 'Session created',
          _ => 'Encrypting...',
        },
      PeerConnectionStage.encrypted => 'Encrypted',
      PeerConnectionStage.failed => 'Connection failed',
    };
  }
}

/// Relay connection status for the overall node.
enum RelayConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

/// Immutable state holding all connection statuses.
class ConnectionStatusState {
  final Map<String, PeerConnectionStatus> peers;
  final RelayConnectionStatus relayStatus;

  const ConnectionStatusState({
    this.peers = const {},
    // Start as "connecting" so the UI shows "Connecting…" before the first WS
    // connect resolves — not a false "Disconnected" (and never a false
    // "Connected", which only the real RelayConnected event sets).
    this.relayStatus = RelayConnectionStatus.connecting,
  });

  ConnectionStatusState copyWithPeer(
      String peerId, PeerConnectionStatus status) {
    return ConnectionStatusState(
      peers: {...peers, peerId: status},
      relayStatus: relayStatus,
    );
  }

  ConnectionStatusState removePeer(String peerId) {
    return ConnectionStatusState(
      peers: Map.of(peers)..remove(peerId),
      relayStatus: relayStatus,
    );
  }

  ConnectionStatusState copyWithRelay(RelayConnectionStatus status) {
    return ConnectionStatusState(
      peers: peers,
      relayStatus: status,
    );
  }

  /// Get peers with meaningful connection activity worth showing in the UI.
  /// Excludes dialing (routine rebootstrap noise) and failed (auto-expires).
  /// Only shows peers that actually made progress: connected or keyExchange.
  List<PeerConnectionStatus> get activePeers => peers.values
      .where((p) =>
          p.stage == PeerConnectionStage.connected ||
          p.stage == PeerConnectionStage.keyExchange)
      .toList();

  /// Human-readable relay label for the dashboard.
  String get relayLabel => switch (relayStatus) {
        RelayConnectionStatus.disconnected => 'Disconnected',
        RelayConnectionStatus.connecting => 'Connecting...',
        RelayConnectionStatus.connected => 'Connected',
        RelayConnectionStatus.reconnecting => 'Reconnecting...',
      };
}

class ConnectionStatusNotifier extends Notifier<ConnectionStatusState> {
  Timer? _cleanupTimer;

  /// Expiry durations.
  static const _failedExpiry = Duration(seconds: 10);
  static const _dialingExpiry = Duration(seconds: 30);

  @override
  ConnectionStatusState build() {
    // Cancel cleanup timer when provider is disposed/rebuilt.
    ref.onDispose(() => _cleanupTimer?.cancel());
    return const ConnectionStatusState();
  }

  /// Schedule a cleanup pass to remove stale entries.
  void _scheduleCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(const Duration(seconds: 5), _runCleanup);
  }

  void _runCleanup() {
    final now = DateTime.now();
    final toRemove = <String>[];
    for (final entry in state.peers.entries) {
      final age = now.difference(entry.value.lastUpdated);
      if (entry.value.stage == PeerConnectionStage.failed &&
          age >= _failedExpiry) {
        toRemove.add(entry.key);
      } else if (entry.value.stage == PeerConnectionStage.dialing &&
          age >= _dialingExpiry) {
        toRemove.add(entry.key);
      }
    }
    if (toRemove.isNotEmpty) {
      var newState = state;
      for (final id in toRemove) {
        newState = newState.removePeer(id);
      }
      state = newState;
    }
    // Reschedule if there are still active (non-encrypted) entries.
    if (state.activePeers.isNotEmpty) {
      _scheduleCleanup();
    }
  }

  void onPeerConnected(String peerId) {
    final current = state.peers[peerId];
    if (current != null &&
        current.stage == PeerConnectionStage.encrypted) {
      return;
    }
    state = state.copyWithPeer(
      peerId,
      PeerConnectionStatus(
        peerId: peerId,
        stage: PeerConnectionStage.connected,
        method: current?.method,
        lastUpdated: DateTime.now(),
      ),
    );
  }

  void onKeyExchangeStarted(String peerId) {
    final current = state.peers[peerId];
    if (current != null &&
        current.stage == PeerConnectionStage.encrypted) {
      return;
    }
    state = state.copyWithPeer(
      peerId,
      (current ??
              PeerConnectionStatus(
                peerId: peerId,
                stage: PeerConnectionStage.keyExchange,
                lastUpdated: DateTime.now(),
              ))
          .copyWith(
        stage: PeerConnectionStage.keyExchange,
        detail: () => 'fetching_prekey',
      ),
    );
  }

  void onKeyExchangeProgress(String peerId, String stage) {
    final current = state.peers[peerId];
    if (current != null &&
        current.stage == PeerConnectionStage.encrypted) {
      return;
    }
    state = state.copyWithPeer(
      peerId,
      (current ??
              PeerConnectionStatus(
                peerId: peerId,
                stage: PeerConnectionStage.keyExchange,
                lastUpdated: DateTime.now(),
              ))
          .copyWith(
        stage: PeerConnectionStage.keyExchange,
        detail: () => stage,
      ),
    );
  }

  void onSessionEstablished(String peerId) {
    final current = state.peers[peerId];
    state = state.copyWithPeer(
      peerId,
      PeerConnectionStatus(
        peerId: peerId,
        stage: PeerConnectionStage.encrypted,
        method: current?.method,
        lastUpdated: DateTime.now(),
      ),
    );
  }

  void onPeerDisconnected(String peerId) {
    state = state.removePeer(peerId);
  }

  void onRelayStatusChanged(String status) {
    final relayStatus = switch (status) {
      'connecting' => RelayConnectionStatus.connecting,
      'connected' => RelayConnectionStatus.connected,
      'reconnecting' => RelayConnectionStatus.reconnecting,
      _ => RelayConnectionStatus.disconnected,
    };
    state = state.copyWithRelay(relayStatus);
  }
}

final connectionStatusProvider =
    NotifierProvider<ConnectionStatusNotifier, ConnectionStatusState>(
        ConnectionStatusNotifier.new);

/// The single source of truth for "am I actually connected", combining the
/// LOCAL node lifecycle (`nodeProvider`) with the REAL relay-WebSocket state
/// (`connectionStatusProvider.relayStatus`).
///
/// The local node reaches `connected` the instant it starts, even with no
/// internet — so it must NOT drive the connection indicator on its own. The
/// node phase only gates loading/error; once the node is up, the relay state
/// decides Connected / Connecting / Reconnecting / Offline.
enum OverallConnection { loading, error, connecting, reconnecting, connected, offline }

extension OverallConnectionLabel on OverallConnection {
  String get label => switch (this) {
        OverallConnection.loading => 'Loading…',
        OverallConnection.error => 'Error',
        OverallConnection.connecting => 'Connecting…',
        OverallConnection.reconnecting => 'Reconnecting…',
        OverallConnection.connected => 'Connected',
        OverallConnection.offline => 'No connection',
      };

  /// True only when fully connected to the relay — the only state that should
  /// render a green/"online" indicator.
  bool get isOnline => this == OverallConnection.connected;
}

/// Combined node + relay connection state for the top-level status indicators
/// (user bar, Home network card). Node error/loading wins; otherwise the real
/// relay WS state drives the label.
final overallConnectionProvider = Provider<OverallConnection>((ref) {
  final node = ref.watch(nodeProvider).status;
  if (node == NodeStatus.error) return OverallConnection.error;
  if (node == NodeStatus.loading || node == NodeStatus.starting) {
    return OverallConnection.connecting;
  }
  // Node is up — the relay WS connection is the ground truth.
  return switch (ref.watch(connectionStatusProvider).relayStatus) {
    RelayConnectionStatus.connected => OverallConnection.connected,
    RelayConnectionStatus.connecting => OverallConnection.connecting,
    RelayConnectionStatus.reconnecting => OverallConnection.reconnecting,
    RelayConnectionStatus.disconnected => OverallConnection.offline,
  };
});

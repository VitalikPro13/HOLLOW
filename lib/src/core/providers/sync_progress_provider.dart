import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks which peer IDs are currently syncing, per-server.
class SyncingPeersNotifier extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() => {};

  void addPeer(String serverId, String peerId) {
    final current = state[serverId] ?? {};
    state = {...state, serverId: {...current, peerId}};
  }

  void clearServer(String serverId) {
    state = Map.of(state)..remove(serverId);
  }
}

final syncingPeersProvider =
    NotifierProvider<SyncingPeersNotifier, Map<String, Set<String>>>(
        SyncingPeersNotifier.new);

/// Is a specific peer currently syncing (across any server)?
final isPeerSyncingProvider = Provider.family<bool, String>((ref, peerId) {
  final syncingPeers = ref.watch(syncingPeersProvider);
  return syncingPeers.values.any((peers) => peers.contains(peerId));
});

/// Accumulated sync progress for a server.
class SyncProgress {
  final int receivedCount;
  final int totalCount;
  const SyncProgress({this.receivedCount = 0, this.totalCount = 0});
}

/// Per-server sync progress accumulator.
class SyncProgressNotifier extends Notifier<Map<String, SyncProgress>> {
  @override
  Map<String, SyncProgress> build() => {};

  void updateProgress(String serverId, int received, int total) {
    final current = state[serverId] ?? const SyncProgress();
    state = {
      ...state,
      serverId: SyncProgress(
        receivedCount: current.receivedCount + received,
        totalCount: current.totalCount + total,
      ),
    };
  }

  void clearServer(String serverId) {
    state = Map.of(state)..remove(serverId);
  }
}

final syncProgressProvider =
    NotifierProvider<SyncProgressNotifier, Map<String, SyncProgress>>(
        SyncProgressNotifier.new);

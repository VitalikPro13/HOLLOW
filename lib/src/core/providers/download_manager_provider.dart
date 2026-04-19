import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';

// ── Data model ───────────────────────────────────────────────

enum DownloadEntryType { savedFile, rebalance }

enum DownloadEntryStatus { active, complete }

class DownloadManagerEntry {
  final String id;
  final DownloadEntryType type;
  final String displayName;
  final DownloadEntryStatus status;
  final String? statusText;
  // Saved-file fields (null for rebalance entries).
  final String? savedPath;
  final bool isImage;
  final bool isVideo;

  const DownloadManagerEntry({
    required this.id,
    required this.type,
    required this.displayName,
    required this.status,
    this.statusText,
    this.savedPath,
    this.isImage = false,
    this.isVideo = false,
  });
}

// ── Saved file record ────────────────────────────────────────

class SavedFileRecord {
  /// User-chosen filename (basename of savedPath).
  final String fileName;

  /// Full destination path chosen in the Save As dialog.
  final String savedPath;

  /// Monotonic sequence for stable ordering (most recent first).
  final int sequence;

  final bool isImage;
  final bool isVideo;

  const SavedFileRecord({
    required this.fileName,
    required this.savedPath,
    required this.sequence,
    this.isImage = false,
    this.isVideo = false,
  });
}

// ── Rebalance tracker ────────────────────────────────────────

class RebalanceTracker {
  final String serverId;
  final int moved;
  final int total;
  final bool completed;

  const RebalanceTracker({
    required this.serverId,
    this.moved = 0,
    this.total = 0,
    this.completed = false,
  });
}

// ── Owned state ──────────────────────────────────────────────

class DownloadManagerOwnedState {
  /// Saved files keyed by savedPath (dedupes re-saves to the same destination).
  final Map<String, SavedFileRecord> savedFiles;
  final Map<String, RebalanceTracker> rebalances;
  final int sequenceCounter;

  const DownloadManagerOwnedState({
    this.savedFiles = const {},
    this.rebalances = const {},
    this.sequenceCounter = 0,
  });

  DownloadManagerOwnedState copyWith({
    Map<String, SavedFileRecord>? savedFiles,
    Map<String, RebalanceTracker>? rebalances,
    int? sequenceCounter,
  }) {
    return DownloadManagerOwnedState(
      savedFiles: savedFiles ?? this.savedFiles,
      rebalances: rebalances ?? this.rebalances,
      sequenceCounter: sequenceCounter ?? this.sequenceCounter,
    );
  }
}

class DownloadManagerNotifier extends Notifier<DownloadManagerOwnedState> {
  @override
  DownloadManagerOwnedState build() => const DownloadManagerOwnedState();

  /// Record a manually-saved file. Called from save-to-disk handlers after
  /// the user has chosen a destination path and the copy/write has succeeded.
  void recordSavedFile({
    required String savedPath,
    bool isImage = false,
    bool isVideo = false,
  }) {
    // Derive filename from path (handle both \ and / separators).
    final normalized = savedPath.replaceAll('\\', '/');
    final fileName = normalized.contains('/')
        ? normalized.substring(normalized.lastIndexOf('/') + 1)
        : normalized;

    final seq = state.sequenceCounter + 1;
    state = state.copyWith(
      savedFiles: {
        ...state.savedFiles,
        savedPath: SavedFileRecord(
          fileName: fileName,
          savedPath: savedPath,
          sequence: seq,
          isImage: isImage,
          isVideo: isVideo,
        ),
      },
      sequenceCounter: seq,
    );
  }

  /// Clear all entries from view — drops saved-file records and
  /// completed rebalance trackers (active rebalances are retained).
  void clearAll() {
    final rebalances = Map.of(state.rebalances)
      ..removeWhere((_, val) => val.completed);
    state = state.copyWith(
      savedFiles: const {},
      rebalances: rebalances,
    );
  }

  /// Remove a single saved-file entry by its saved path.
  void clearSavedFile(String savedPath) {
    final updated = Map.of(state.savedFiles)..remove(savedPath);
    state = state.copyWith(savedFiles: updated);
  }

  // ── Rebalance events ────────────────────────────────────────

  void onRebalanceStarted(String serverId, int shardsToMove) {
    state = state.copyWith(
      rebalances: {
        ...state.rebalances,
        serverId: RebalanceTracker(
          serverId: serverId,
          total: shardsToMove,
        ),
      },
    );
  }

  void onRebalanceProgress(String serverId, int moved, int total) {
    final existing = state.rebalances[serverId];
    state = state.copyWith(
      rebalances: {
        ...state.rebalances,
        serverId: RebalanceTracker(
          serverId: serverId,
          moved: moved,
          total: total > 0 ? total : (existing?.total ?? total),
        ),
      },
    );
  }

  void onRebalanceCompleted(String serverId) {
    final existing = state.rebalances[serverId];
    if (existing == null) return;
    state = state.copyWith(
      rebalances: {
        ...state.rebalances,
        serverId: RebalanceTracker(
          serverId: serverId,
          moved: existing.total,
          total: existing.total,
          completed: true,
        ),
      },
    );
  }
}

final downloadManagerStateProvider =
    NotifierProvider<DownloadManagerNotifier, DownloadManagerOwnedState>(
  DownloadManagerNotifier.new,
);

// ── Computed entries ─────────────────────────────────────────

final downloadManagerEntriesProvider =
    Provider<List<DownloadManagerEntry>>((ref) {
  final owned = ref.watch(downloadManagerStateProvider);
  final entries = <DownloadManagerEntry>[];

  // 1. Active rebalances first.
  for (final rebal in owned.rebalances.values.where((r) => !r.completed)) {
    entries.add(DownloadManagerEntry(
      id: 'rebal:${rebal.serverId}',
      type: DownloadEntryType.rebalance,
      displayName: 'Shard rebalance',
      status: DownloadEntryStatus.active,
      statusText: rebal.total > 0
          ? 'Moving ${rebal.moved}/${rebal.total} shards'
          : 'In progress...',
    ));
  }

  // 2. Saved files, most recent first.
  final savedList = owned.savedFiles.values.toList()
    ..sort((a, b) => b.sequence.compareTo(a.sequence));
  for (final saved in savedList) {
    entries.add(DownloadManagerEntry(
      id: 'saved:${saved.savedPath}',
      type: DownloadEntryType.savedFile,
      displayName: saved.fileName,
      status: DownloadEntryStatus.complete,
      savedPath: saved.savedPath,
      isImage: saved.isImage,
      isVideo: saved.isVideo,
    ));
  }

  // 3. Completed rebalances at the bottom.
  for (final rebal in owned.rebalances.values.where((r) => r.completed)) {
    entries.add(DownloadManagerEntry(
      id: 'rebal:${rebal.serverId}',
      type: DownloadEntryType.rebalance,
      displayName: 'Shard rebalance',
      status: DownloadEntryStatus.complete,
      statusText: 'Complete',
    ));
  }

  return entries;
});

/// Share downloads dismissed from the Downloads popup (session-only).
final dismissedShareDownloadsProvider = StateProvider<Set<String>>((ref) => {});

/// Badge count — active rebalances + share downloads show a dot on the icon.
/// Saved files don't pulse the badge (they're passive history).
final activeTransferCountProvider = Provider<int>((ref) {
  final owned = ref.watch(downloadManagerStateProvider);
  final shares = ref.watch(shareTabProvider);
  final activeRebalances = owned.rebalances.values.where((r) => !r.completed).length;
  final activeShares = shares.where((s) => s.state == 'downloading').length;
  return activeRebalances + activeShares;
});

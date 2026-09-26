import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

final shareTabOpenProvider = StateProvider<bool>((ref) => false);

/// Whether the share list has arrived (it comes later, as an event) and
/// whether asking for it failed, so an empty list is never shown before then.
typedef ShareListStatus = ({bool loaded, bool failed});

final shareListStatusProvider =
    StateProvider<ShareListStatus>((ref) => (loaded: false, failed: false));

class ShareItemState {
  final String rootHash;
  final String fileName;
  final int totalSize;
  final int chunksHave;
  final int chunksTotal;
  final int seeders;
  final int leechers;
  final int bytesPerSec;
  final bool seeding;
  final int bytesUploaded;
  final String state;
  final String shareLink;
  final String? diskPath;
  final String? error;
  final int createdAt;
  final String? serverId;
  final String? contextType;

  const ShareItemState({
    required this.rootHash,
    required this.fileName,
    required this.totalSize,
    this.chunksHave = 0,
    this.chunksTotal = 0,
    this.seeders = 0,
    this.leechers = 0,
    this.bytesPerSec = 0,
    this.seeding = false,
    this.bytesUploaded = 0,
    this.state = 'downloading',
    this.shareLink = '',
    this.diskPath,
    this.error,
    this.createdAt = 0,
    this.serverId,
    this.contextType,
  });

  ShareItemState copyWith({
    int? chunksHave,
    int? chunksTotal,
    int? seeders,
    int? leechers,
    int? bytesPerSec,
    bool? seeding,
    int? bytesUploaded,
    String? state,
    String? shareLink,
    String? diskPath,
    String? error,
  }) {
    return ShareItemState(
      rootHash: rootHash,
      fileName: fileName,
      totalSize: totalSize,
      chunksHave: chunksHave ?? this.chunksHave,
      chunksTotal: chunksTotal ?? this.chunksTotal,
      seeders: seeders ?? this.seeders,
      leechers: leechers ?? this.leechers,
      bytesPerSec: bytesPerSec ?? this.bytesPerSec,
      seeding: seeding ?? this.seeding,
      bytesUploaded: bytesUploaded ?? this.bytesUploaded,
      state: state ?? this.state,
      shareLink: shareLink ?? this.shareLink,
      diskPath: diskPath ?? this.diskPath,
      error: error ?? this.error,
      createdAt: createdAt,
      serverId: serverId,
      contextType: contextType,
    );
  }
}

class ShareTabNotifier extends Notifier<List<ShareItemState>> {
  @override
  List<ShareItemState> build() => [];

  Future<void> loadAll() async {
    final status = ref.read(shareListStatusProvider.notifier);
    status.state = (loaded: status.state.loaded, failed: false);
    try {
      await share_api.shareList();
    } catch (e) {
      debugPrint('[HOLLOW-SHARE] loadAll failed: $e');
      status.state = (loaded: status.state.loaded, failed: true);
    }
  }

  // The create command only queues: the outcome arrives as ShareCreated, or
  // as a ShareFailed with an empty root hash (no row exists to carry it).
  Completer<void>? _pendingCreate;
  String? _pendingCreateName;

  /// Shares the file at [sourcePath] and completes once the node reports the
  /// share made, throws its failure, or gives up quietly after [timeout].
  Future<void> createFromFile(
    String sourcePath, {
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final completer = Completer<void>();
    _pendingCreate = completer;
    _pendingCreateName = p.basename(sourcePath);
    try {
      await share_api.shareCreateFromFile(sourcePath: sourcePath);
      await completer.future.timeout(timeout, onTimeout: () {});
    } finally {
      if (identical(_pendingCreate, completer)) {
        _pendingCreate = null;
        _pendingCreateName = null;
      }
    }
  }

  void handleShareList(List<network_api.ShareEntry> entries) {
    ref.read(shareListStatusProvider.notifier).state =
        (loaded: true, failed: false);
    final existing = {for (final s in state) s.rootHash: s};
    state = entries.map((e) {
      final prev = existing[e.rootHash];
      return ShareItemState(
        rootHash: e.rootHash,
        fileName: e.fileName,
        totalSize: e.totalSize.toInt(),
        chunksHave: prev?.chunksHave ?? e.chunksHave,
        chunksTotal: prev?.chunksTotal ?? e.chunksTotal,
        state: e.state,
        seeding: prev?.seeding ?? e.seeding,
        seeders: prev?.seeders ?? 0,
        leechers: prev?.leechers ?? 0,
        bytesPerSec: prev?.bytesPerSec ?? 0,
        diskPath: e.diskPath,
        bytesUploaded: prev?.bytesUploaded ?? e.bytesUploaded.toInt(),
        shareLink: e.shareLink,
        createdAt: e.createdAt.toInt(),
        serverId: e.serverId,
        contextType: e.contextType,
      );
    }).toList();
  }

  void handleShareProgress(
    String rootHash, int chunksHave, int chunksTotal, int seeders, int leechers, int bytesPerSec,
  ) {
    state = [
      for (final item in state)
        if (item.rootHash == rootHash)
          item.copyWith(
            chunksHave: chunksHave,
            chunksTotal: chunksTotal,
            seeders: seeders,
            leechers: leechers,
            bytesPerSec: bytesPerSec,
          )
        else
          item,
    ];
  }

  void handleShareCompleted(String rootHash, String diskPath) {
    state = [
      for (final item in state)
        if (item.rootHash == rootHash)
          item.copyWith(state: 'completed', diskPath: diskPath, seeding: true)
        else
          item,
    ];
  }

  void handleShareFailed(String rootHash, String error) {
    if (rootHash.isEmpty) {
      final pending = _pendingCreate;
      if (pending != null && !pending.isCompleted) pending.completeError(error);
      return;
    }
    if (error == 'Cancelled' || error == 'No seeders found') {
      state = state.where((s) =>
          s.rootHash != rootHash || s.state == 'completed').toList();
    } else {
      state = [
        for (final item in state)
          if (item.rootHash == rootHash)
            item.copyWith(state: 'failed', error: error)
          else
            item,
      ];
    }
  }

  void handleShareCreated(
    String rootHash, String link, String fileName, int totalSize,
  ) {
    final pending = _pendingCreate;
    if (pending != null &&
        !pending.isCompleted &&
        fileName == _pendingCreateName) {
      pending.complete();
    }
    final exists = state.any((s) => s.rootHash == rootHash);
    if (exists) {
      state = [
        for (final item in state)
          if (item.rootHash == rootHash)
            item.copyWith(state: 'completed', seeding: true, shareLink: link)
          else
            item,
      ];
    } else {
      state = [
        ShareItemState(
          rootHash: rootHash,
          fileName: fileName,
          totalSize: totalSize,
          state: 'completed',
          seeding: true,
          shareLink: link,
          chunksHave: 1,
          chunksTotal: 1,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
        ...state,
      ];
    }
  }

  void handleShareManifestReady(
    String rootHash, String fileName, int totalSize, int chunkCount,
  ) {
    pendingManifests[rootHash] = (fileName, totalSize, chunkCount);
    ref.notifyListeners();
  }

  void clearPendingManifest(String rootHash) {
    pendingManifests.remove(rootHash);
  }

  void startDownload(String rootHash, String shareLink) {
    final manifest = pendingManifests[rootHash];
    if (manifest == null) return;
    final (fileName, totalSize, chunkCount) = manifest;
    pendingManifests.remove(rootHash);
    state = [
      ShareItemState(
        rootHash: rootHash,
        fileName: fileName,
        totalSize: totalSize,
        chunksTotal: chunkCount,
        state: 'downloading',
        shareLink: shareLink,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
      ...state,
    ];
  }

  final Map<String, (String, int, int)> pendingManifests = {};

  void setShareLink(String rootHash, String link) {
    state = [
      for (final item in state)
        if (item.rootHash == rootHash)
          item.copyWith(shareLink: link)
        else
          item,
    ];
  }

  void handleShareSeedingChanged(
    String rootHash, bool seeding, int seeders, int leechers, int bytesUploaded,
  ) {
    state = [
      for (final item in state)
        if (item.rootHash == rootHash)
          item.copyWith(seeding: seeding, seeders: seeders, leechers: leechers, bytesUploaded: bytesUploaded)
        else
          item,
    ];
  }

  void removeShare(String rootHash) {
    state = state.where((s) => s.rootHash != rootHash).toList();
  }
}

final shareTabProvider =
    NotifierProvider<ShareTabNotifier, List<ShareItemState>>(
        ShareTabNotifier.new);

List<ShareItemState> downloadingShares(List<ShareItemState> shares) =>
    shares.where((s) => s.state == 'downloading' || s.state == 'failed').toList();

List<ShareItemState> seedingShares(List<ShareItemState> shares) =>
    shares.where((s) => s.state == 'completed').toList();

const _shareDownloadPathKey = 'share_download_path';

final shareDownloadPathProvider =
    AsyncNotifierProvider<ShareDownloadPathNotifier, String>(
        ShareDownloadPathNotifier.new);

class ShareDownloadPathNotifier extends AsyncNotifier<String> {
  @override
  Future<String> build() async {
    final val = await storage_api.loadSetting(key: _shareDownloadPathKey);
    return val ?? '';
  }

  Future<void> setPath(String path) async {
    await storage_api.saveSetting(key: _shareDownloadPathKey, value: path);
    state = AsyncData(path);
  }
}
